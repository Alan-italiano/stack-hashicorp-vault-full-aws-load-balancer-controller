#!/usr/bin/env python3
import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request


# The TLS context is initialized at runtime after Terraform passes the Vault CA.
TLS_CONTEXT = None
LOG_FILE_HANDLE = None


def initialize_log_file(log_file):
    global LOG_FILE_HANDLE
    if not log_file:
        return

    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    LOG_FILE_HANDLE = open(log_file, "a", encoding="utf-8")


# Emit bootstrap progress in a consistent format for Terraform/local-exec logs.
def log(message):
    rendered = f"[vault-bootstrap] {message}"
    print(rendered, flush=True)
    if LOG_FILE_HANDLE is not None:
        LOG_FILE_HANDLE.write(rendered + "\n")
        LOG_FILE_HANDLE.flush()


# Build an HTTPS context that validates the Vault CA chain while tolerating the
# local port-forward hostname mismatch to 127.0.0.1.
def build_tls_context(vault_ca_cert_b64):
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=base64.b64decode(vault_ca_cert_b64).decode("utf-8"))
    context.check_hostname = False
    return context


# Run shell commands used by the bootstrap flow and surface stdout/stderr on failure.
def run(command, capture_output=True, check=True):
    result = subprocess.run(
        command,
        text=True,
        capture_output=capture_output,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
    return result


# Send authenticated requests to the Vault HTTP API and normalize expected responses.
def request(method, url, payload=None, token=None, expected_statuses=None):
    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    if token:
        headers["X-Vault-Token"] = token

    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=10, context=TLS_CONTEXT) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        if expected_statuses and exc.code in expected_statuses:
            return exc.code, json.loads(body) if body else {}
        raise RuntimeError(f"Vault API {method} {url} failed with {exc.code}: {body}") from exc


# Reserve a random localhost port for kubectl port-forward to expose Vault temporarily.
def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# Wait until the first Vault pod exists and reaches Running so the bootstrap can begin.
def wait_for_pod_running(namespace, pod_name):
    log(f"Waiting for {pod_name} to reach Running phase")
    deadline = time.time() + 900
    while time.time() < deadline:
        result = run(
            [
                "kubectl",
                "-n",
                namespace,
                "get",
                "pod",
                pod_name,
                "-o",
                "jsonpath={.status.phase}",
            ],
            check=False,
        )
        phase = result.stdout.strip()
        if result.returncode == 0 and phase == "Running":
            log(f"{pod_name} is Running")
            return
        time.sleep(5)

    raise RuntimeError(f"{pod_name} did not reach Running phase within 15 minutes")


# Open a local tunnel to Vault so bootstrap uses the Kubernetes API as its transport.
def start_port_forward(namespace, pod_name, local_port):
    log(f"Starting kubectl port-forward from {pod_name} to 127.0.0.1:{local_port}")
    process = subprocess.Popen(
        [
            "kubectl",
            "-n",
            namespace,
            "port-forward",
            f"pod/{pod_name}",
            f"{local_port}:8200",
            "--address",
            "127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return process


# Poll Vault health until the API becomes reachable through the local port-forward.
def wait_for_vault(base_url):
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            status, _ = request(
                "GET",
                f"{base_url}/v1/sys/health",
                expected_statuses={200, 429, 472, 473, 501, 503},
            )
            if status in {200, 429, 472, 473, 501, 503}:
                log(f"Vault is reachable with health status {status}")
                return
        except Exception:
            pass
        time.sleep(5)

    raise RuntimeError("Vault did not become reachable within 10 minutes")


# Load previously persisted initialization data so reruns can reuse the root token safely.
def load_existing_credentials(output_file):
    if not os.path.exists(output_file):
        return None

    with open(output_file, "r", encoding="utf-8") as handle:
        return json.load(handle)


# Persist the initialization response produced by Vault for later administrative actions.
def persist_credentials(output_file, init_response):
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    payload = {
        "initialized_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "root_token": init_response["root_token"],
        "recovery_keys_b64": init_response.get("recovery_keys_b64", []),
        "recovery_keys_hex": init_response.get("recovery_keys_hex", []),
    }
    with open(output_file, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    log(f"Bootstrap credentials saved to {output_file}")


# Initialize Vault once and return the root token; on reruns, reuse the stored token.
def ensure_initialized(base_url, output_file):
    status, payload = request("GET", f"{base_url}/v1/sys/init")
    if status != 200:
        raise RuntimeError(f"Unexpected status from /sys/init: {status}")

    if payload.get("initialized"):
        log("Vault is already initialized")
        existing = load_existing_credentials(output_file)
        if not existing or not existing.get("root_token"):
            raise RuntimeError(
                "Vault is already initialized, but no local root token file was found at "
                f"{output_file}. Restore that file or re-run with a known root token manually."
            )
        return existing["root_token"]

    log("Vault is not initialized yet, running initialization")
    _, init_response = request(
        "PUT",
        f"{base_url}/v1/sys/init",
        payload={
            "recovery_shares": 5,
            "recovery_threshold": 3,
        },
        expected_statuses={200},
    )
    persist_credentials(output_file, init_response)
    return init_response["root_token"]


# Ensure the kv-v2 secrets engine exists at kv/ for generic secret storage.
def ensure_kv_v2(base_url, token):
    _, mounts = request("GET", f"{base_url}/v1/sys/mounts", token=token)
    kv_mount = mounts.get("kv/")
    if kv_mount:
        if kv_mount.get("type") != "kv" or kv_mount.get("options", {}).get("version") != "2":
            raise RuntimeError("A mount already exists at kv/ but it is not kv-v2")
        log("kv-v2 is already enabled at kv/")
        return

    log("Enabling kv-v2 at kv/")
    request(
        "POST",
        f"{base_url}/v1/sys/mounts/kv",
        payload={"type": "kv", "options": {"version": "2"}},
        token=token,
        expected_statuses={204},
    )


# Enable and configure the Kubernetes auth method so workloads can authenticate to Vault.
def ensure_kubernetes_auth(base_url, token, namespace, service_account, kubernetes_host, kubernetes_ca_b64):
    _, auth_methods = request("GET", f"{base_url}/v1/sys/auth", token=token)
    if "kubernetes/" not in auth_methods:
        log("Enabling auth method kubernetes")
        request(
            "POST",
            f"{base_url}/v1/sys/auth/kubernetes",
            payload={"type": "kubernetes"},
            token=token,
            expected_statuses={204},
        )
    else:
        log("Auth method kubernetes is already enabled")

    log("Issuing token for Vault service account")
    token_result = run(
        [
            "kubectl",
            "-n",
            namespace,
            "create",
            "token",
            service_account,
            "--duration=24h",
        ]
    )
    reviewer_jwt = token_result.stdout.strip()
    if not reviewer_jwt:
        raise RuntimeError("kubectl create token returned an empty reviewer JWT")

    kubernetes_ca_cert = base64.b64decode(kubernetes_ca_b64).decode("utf-8")
    log("Configuring Vault Kubernetes auth backend")
    request(
        "POST",
        f"{base_url}/v1/auth/kubernetes/config",
        payload={
            "token_reviewer_jwt": reviewer_jwt,
            "kubernetes_host": kubernetes_host,
            "kubernetes_ca_cert": kubernetes_ca_cert,
        },
        token=token,
        expected_statuses={204},
    )


# Enable the file audit device and send structured audit entries to stdout.
def ensure_audit_stdout(base_url, token):
    _, audit_devices = request("GET", f"{base_url}/v1/sys/audit", token=token)
    existing = audit_devices.get("file/")
    if existing:
        if existing.get("type") != "file":
            raise RuntimeError("An audit device already exists at file/ but it is not of type file")
        log("stdout file audit device is already enabled")
        return

    log("Enabling stdout file audit device with json format")
    request(
        "PUT",
        f"{base_url}/v1/sys/audit/file",
        payload={
            "type": "file",
            "options": {
                "file_path": "stdout",
                "format": "json",
            },
        },
        token=token,
        expected_statuses={204},
    )


# Enable internal client usage counters and keep one year of retained usage data.
def ensure_client_counters(base_url, token):
    log("Configuring Vault client usage counters")
    request(
        "POST",
        f"{base_url}/v1/sys/internal/counters/config",
        payload={
            "enabled": "enable",
            "retention_months": 12,
        },
        token=token,
        expected_statuses={200, 204},
    )


# Ensure the database secrets engine is mounted before configuring any connection.
def ensure_database_secrets_engine(base_url, token):
    _, mounts = request("GET", f"{base_url}/v1/sys/mounts", token=token)
    database_mount = mounts.get("database/")
    if database_mount:
        if database_mount.get("type") != "database":
            raise RuntimeError("A mount already exists at database/ but it is not of type database")
        log("database secrets engine is already enabled at database/")
        return

    log("Enabling database secrets engine at database/")
    request(
        "POST",
        f"{base_url}/v1/sys/mounts/database",
        payload={"type": "database"},
        token=token,
        expected_statuses={204},
    )


# Create or update the PostgreSQL connection used by Vault to issue dynamic credentials.
def ensure_postgres_connection(base_url, token, args):
    log(f"Configuring PostgreSQL connection {args.vault_db_connection_name}")
    request(
        "POST",
        f"{base_url}/v1/database/config/{args.vault_db_connection_name}",
        payload={
            "plugin_name": "postgresql-database-plugin",
            "allowed_roles": args.vault_db_role_name,
            "connection_url": "postgresql://{{username}}:{{password}}@%s:%s/%s?sslmode=disable"
            % (args.postgres_host, args.postgres_port, args.postgres_database_name),
            "username": args.postgres_admin_username,
            "password": args.postgres_admin_password,
        },
        token=token,
        expected_statuses={204},
    )


# Create or update the Vault database role that issues short-lived PostgreSQL superusers.
def ensure_postgres_role(base_url, token, args):
    log(f"Configuring dynamic PostgreSQL role {args.vault_db_role_name}")
    request(
        "POST",
        f"{base_url}/v1/database/roles/{args.vault_db_role_name}",
        payload={
            "db_name": args.vault_db_connection_name,
            "creation_statements": [
                "CREATE ROLE \"{{name}}\" WITH SUPERUSER LOGIN ENCRYPTED PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
            ],
            "default_ttl": "10m",
            "max_ttl": "1h",
        },
        token=token,
        expected_statuses={204},
    )


# Define the Terraform-provided inputs required to initialize Vault and configure integrations.
def parse_args():
    parser = argparse.ArgumentParser(description="Bootstrap Vault after Terraform apply")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--service-account", required=True)
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--kubernetes-host", required=True)
    parser.add_argument("--kubernetes-ca-b64", required=True)
    parser.add_argument("--vault-ca-cert-b64", required=True)
    parser.add_argument("--output-file", required=True)
    parser.add_argument("--log-file", default=None)
    parser.add_argument("--postgres-host", required=True)
    parser.add_argument("--postgres-port", required=True, type=int)
    parser.add_argument("--postgres-database-name", required=True)
    parser.add_argument("--postgres-admin-username", required=True)
    parser.add_argument("--postgres-admin-password", required=True)
    parser.add_argument("--vault-db-connection-name", default="postgres")
    parser.add_argument("--vault-db-role-name", default="postgres-dynamic")
    return parser.parse_args()


# Orchestrate the full bootstrap sequence from connectivity checks to engine/auth/database setup.
def main():
    global TLS_CONTEXT

    args = parse_args()
    initialize_log_file(args.log_file)
    if args.log_file:
        log(f"Writing debug log to {args.log_file}")
    TLS_CONTEXT = build_tls_context(args.vault_ca_cert_b64)

    pod_name = "vault-0"
    wait_for_pod_running(args.namespace, pod_name)

    local_port = find_free_port()
    process = start_port_forward(args.namespace, pod_name, local_port)
    try:
        base_url = f"https://127.0.0.1:{local_port}"
        wait_for_vault(base_url)
        root_token = ensure_initialized(base_url, args.output_file)
        ensure_kv_v2(base_url, root_token)
        ensure_kubernetes_auth(
            base_url,
            root_token,
            args.namespace,
            args.service_account,
            args.kubernetes_host,
            args.kubernetes_ca_b64,
        )
        ensure_audit_stdout(base_url, root_token)
        ensure_client_counters(base_url, root_token)
        ensure_database_secrets_engine(base_url, root_token)
        ensure_postgres_connection(base_url, root_token, args)
        ensure_postgres_role(base_url, root_token, args)
        log("Vault bootstrap completed successfully")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        if LOG_FILE_HANDLE is not None:
            LOG_FILE_HANDLE.close()


# Fail fast with a clear message so Terraform surfaces bootstrap issues immediately.
if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log(str(exc))
        if LOG_FILE_HANDLE is not None:
            LOG_FILE_HANDLE.close()
        sys.exit(1)
