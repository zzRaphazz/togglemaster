#!/bin/bash
set -euo pipefail

# ============================================================
# User-Data Script for ToggleMaster on Amazon Linux 2023
# ============================================================
# PREREQUISITES (configure BEFORE launching the EC2 instance):
#
# 1. IAM ROLE attached to the EC2 instance with this policy:
#    {
#      "Version": "2012-10-17",
#      "Statement": [
#        {
#          "Effect": "Allow",
#          "Action": "secretsmanager:GetSecretValue",
#          "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT>:secret:<SECRET-NAME>"
#        }
#      ]
#    }
#
# 2. Security Groups:
#    - EC2 SG: inbound 22 (SSH) + 5000 (app)
#    - RDS SG: inbound 5432 from EC2 SG
#
# 3. Replace the CONFIGURATION section below before using!
# ============================================================

# ============================================================
# CONFIGURATION - EDIT THESE VALUES BEFORE USING
# ============================================================
GIT_REPO_URL="https://github.com/zzRaphazz/togglemaster.git"   # <<< CHANGE ME
APP_DIR="/opt/togglemaster"
APP_USER="togglemaster"
SECRET_NAME="prd/rds/togglemaster"   # <<< CHANGE ME (name of your Secrets Manager secret)
AWS_REGION="sa-east-1"               # <<< CHANGE ME (region where your Secrets Manager secret lives)
USE_SECRETS_MANAGER="true"
DB_NAME=""                           # <<< OPTIONAL: set only if secret does NOT contain dbname/database
GUNICORN_WORKERS=2
GUNICORN_BIND="0.0.0.0:5000"
LOG_DIR="/var/log/togglemaster"
# ============================================================
# END OF CONFIGURATION
# ============================================================

echo "=========================================="
echo "Starting ToggleMaster EC2 Bootstrap..."
echo "=========================================="

# ------------------------------------------------------------
# Step 1: System update + install base dependencies
# ------------------------------------------------------------
echo "[1/7] Updating system packages..."
dnf update -y

echo "[1/7] Installing system packages (git, python3, postgresql client, aws cli)..."
dnf install -y \
    git \
    python3 \
    python3-pip \
    python3-venv \
    postgresql \
    aws-cfn-bootstrap \
    amazon-cloudwatch-agent

# Make sure python3 points to default python
alternatives --set python /usr/bin/python3 || true

# ------------------------------------------------------------
# Step 2: Create dedicated non-root user to run the app
# ------------------------------------------------------------
echo "[2/7] Creating dedicated application user: ${APP_USER}"
if ! id "${APP_USER}" &>/dev/null; then
    useradd --system --create-home --shell /sbin/nologin "${APP_USER}"
    echo "  -> User ${APP_USER} created."
else
    echo "  -> User ${APP_USER} already exists, skipping creation."
fi

# ------------------------------------------------------------
# Step 3: Clone or update application code
# ------------------------------------------------------------
echo "[3/7] Deploying application code to ${APP_DIR}..."
if [ ! -d "${APP_DIR}" ]; then
    echo "  -> Cloning repository from ${GIT_REPO_URL}..."
    git clone "${GIT_REPO_URL}" "${APP_DIR}"
else
    echo "  -> Directory ${APP_DIR} already exists. Pulling latest changes..."
    cd "${APP_DIR}" && git pull origin $(git rev-parse --abbrev-ref HEAD) || true
fi

cd "${APP_DIR}"

# ------------------------------------------------------------
# Step 4: Setup Python virtual environment + dependencies
# ------------------------------------------------------------
echo "[4/7] Setting up Python virtual environment..."
VENV_DIR="${APP_DIR}/venv"
if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
fi
VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

echo "  -> Upgrading pip/setuptools..."
"${VENV_PIP}" install --upgrade pip setuptools wheel

# Safety fix: patch requirements.txt if malformed (concatenated deps or missing python-dotenv)
REQ_FILE="${APP_DIR}/requirements.txt"
echo "  -> Checking requirements.txt for known issues..."
"${VENV_PYTHON}" <<'PYFIX'
import re, sys
path = "/opt/togglemaster/requirements.txt"
with open(path, "r") as f:
    content = f.read()

original = content
# Fix malformed lines like "psycopg2-binary==2.9.12boto3gunicorn==26.0.0"
fixed_lines = []
for line in content.splitlines():
    s = line.strip()
    if not s:
        continue
    # If a line contains multiple == patterns concatenated without newlines
    matches = list(re.finditer(r'([A-Za-z0-9_.\-]+(?:==[A-Za-z0-9_.\-]+)?)', s))
    if len(matches) > 1:
        for m in matches:
            fixed_lines.append(m.group(1))
    else:
        fixed_lines.append(s)

# Ensure python-dotenv is present (app.py uses `from dotenv import load_dotenv`)
has_dotenv = any(re.match(r'^python-dotenv\b', l) for l in fixed_lines)
if not has_dotenv:
    fixed_lines.append("python-dotenv")

new_content = "\n".join(fixed_lines) + "\n"
if new_content != original:
    with open(path, "w") as f:
        f.write(new_content)
    print("requirements.txt was fixed (malformed lines / missing deps).")
else:
    print("requirements.txt looks ok.")
PYFIX

echo "  -> Installing Python dependencies from requirements.txt..."
"${VENV_PIP}" install --no-cache-dir -r "${REQ_FILE}"

# Ensure entrypoint.sh is executable
if [ -f "${APP_DIR}/entrypoint.sh" ]; then
    chmod +x "${APP_DIR}/entrypoint.sh"
fi

# ------------------------------------------------------------
# Step 5: Secrets Manager -> environment file (loaded by systemd)
# ------------------------------------------------------------
echo "[5/7] Setting up Secrets Manager integration..."
ENV_FILE="/etc/togglemaster/togglemaster.env"
SECRETS_SCRIPT="/usr/local/bin/togglemaster-fetch-secrets"

mkdir -p /etc/togglemaster
chmod 755 /etc/togglemaster

# Create helper script that fetches the secret + writes .env file
cat > "${SECRETS_SCRIPT}" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

# ---- Parameters ----
SECRET_NAME="${SECRET_NAME_PLACEHOLDER}"
AWS_REGION="${AWS_REGION_PLACEHOLDER}"
USE_SECRETS_MANAGER="${USE_SECRETS_MANAGER_PLACEHOLDER}"
DB_NAME="${DB_NAME_PLACEHOLDER}"
ENV_FILE="/etc/togglemaster/togglemaster.env"

# ---- Base env vars that never come from Secrets Manager ----
cat > "${ENV_FILE}" <<EOF
AWS_REGION=${AWS_REGION}
SECRET_NAME=${SECRET_NAME}
USE_SECRETS_MANAGER=${USE_SECRETS_MANAGER}
EOF

if [ "${USE_SECRETS_MANAGER}" != "true" ]; then
    echo "USE_SECRETS_MANAGER != true; skipping Secrets Manager fetch."
    if [ -n "${DB_NAME}" ]; then
        echo "DB_NAME=${DB_NAME}" >> "${ENV_FILE}"
    fi
    chmod 640 "${ENV_FILE}"
    exit 0
fi

# ---- Fetch secret via AWS CLI (relies on EC2 Instance Role) ----
set +e
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET_NAME}" \
    --region "${AWS_REGION}" \
    --query 'SecretString' \
    --output text 2>&1)
FETCH_EXIT=$?
set -e

if [ ${FETCH_EXIT} -ne 0 ]; then
    echo "ERROR: Failed to fetch secret '${SECRET_NAME}' from Secrets Manager (region=${AWS_REGION}):" >&2
    echo "${SECRET_JSON}" >&2
    echo "Check that the EC2 instance role has secretsmanager:GetSecretValue on this secret." >&2
    # Still write env file so service can read SECRET_NAME/AWS_REGION
    chmod 640 "${ENV_FILE}"
    exit 1
fi

# Map Secrets Manager keys -> DB_* env vars expected by app.py + entrypoint.sh
DB_HOST=$(/usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print(s.get('host') or s.get('hostname') or '')" "${SECRET_JSON}")
DB_PORT=$(/usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print(s.get('port') or s.get('PORT') or '5432')" "${SECRET_JSON}")
DB_NAME_FROM_SECRET=$(/usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print(s.get('dbname') or s.get('database') or s.get('DB_NAME') or s.get('dbInstanceIdentifier') or '')" "${SECRET_JSON}")
DB_USER=$(/usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print(s.get('username') or s.get('user') or '')" "${SECRET_JSON}")
DB_PASSWORD=$(/usr/bin/python3 -c "import json,sys; s=json.loads(sys.argv[1]); print(s.get('password') or '')" "${SECRET_JSON}")

# Any EXTRA key/value in the secret is exported directly as an env var too
EXTRA_KV=$(/usr/bin/python3 <<PY
import json,sys,shlex
s=json.loads(sys.argv[1])
reserved={"host","hostname","port","PORT","dbname","database","DB_NAME","dbInstanceIdentifier","username","user","password"}
for k,v in s.items():
    if k.lower() in {r.lower() for r in reserved}:
        continue
    if isinstance(v,(dict,list)):
        continue
    print(f"{k}={shlex.quote(str(v))}")
PY
"${SECRET_JSON}")

# Append DB_* mapping + extra vars to env file
{
    [ -n "${DB_HOST}" ]         && echo "DB_HOST=${DB_HOST}"
    [ -n "${DB_PORT}" ]         && echo "DB_PORT=${DB_PORT}"
    if [ -n "${DB_NAME}" ]; then
        echo "DB_NAME=${DB_NAME}"
    elif [ -n "${DB_NAME_FROM_SECRET}" ]; then
        echo "DB_NAME=${DB_NAME_FROM_SECRET}"
    fi
    [ -n "${DB_USER}" ]         && echo "DB_USER=${DB_USER}"
    [ -n "${DB_PASSWORD}" ]     && echo "DB_PASSWORD=${DB_PASSWORD}"
    [ -n "${EXTRA_KV}" ]        && echo "${EXTRA_KV}"
} >> "${ENV_FILE}"

# Secure the env file (readable only by root and togglemaster group)
chmod 640 "${ENV_FILE}"
chown root:togglemaster "${ENV_FILE}"

echo "Environment file generated at ${ENV_FILE} with Secrets Manager values."
SCRIPT

# Inject the placeholders with actual config values
sed -i "s|\${SECRET_NAME_PLACEHOLDER}|${SECRET_NAME}|g"           "${SECRETS_SCRIPT}"
sed -i "s|\${AWS_REGION_PLACEHOLDER}|${AWS_REGION}|g"             "${SECRETS_SCRIPT}"
sed -i "s|\${USE_SECRETS_MANAGER_PLACEHOLDER}|${USE_SECRETS_MANAGER}|g" "${SECRETS_SCRIPT}"
sed -i "s|\${DB_NAME_PLACEHOLDER}|${DB_NAME}|g"                   "${SECRETS_SCRIPT}"

chmod 750 "${SECRETS_SCRIPT}"
chown root:togglemaster "${SECRETS_SCRIPT}"

# Run it now to generate the initial env file
echo "  -> Running secrets fetch for the first time..."
"${SECRETS_SCRIPT}"

# ------------------------------------------------------------
# Step 6: Create log directory + fix ownership
# ------------------------------------------------------------
echo "[6/7] Configuring permissions and log directory..."
mkdir -p "${LOG_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}" "${LOG_DIR}"
chmod 750 "${APP_DIR}" "${LOG_DIR}"

# Give app user read access to the secrets env file (via group)
usermod -a -G togglemaster "${APP_USER}" || true
chmod 640 "${ENV_FILE}" 2>/dev/null || true
chown root:"${APP_USER}" "${ENV_FILE}" 2>/dev/null || true

# ------------------------------------------------------------
# Step 7: Create systemd service
# ------------------------------------------------------------
echo "[7/7] Creating systemd service togglemaster.service..."

SERVICE_FILE="/etc/systemd/system/togglemaster.service"

cat > "${SERVICE_FILE}" <<SVC
[Unit]
Description=ToggleMaster Flask API (Gunicorn)
After=network.target
Wants=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}

# Load environment variables (Secrets Manager values + base config)
EnvironmentFile=${ENV_FILE}

# Re-fetch secrets on every restart so secret rotation takes effect on restart
ExecStartPre=+/usr/local/bin/togglemaster-fetch-secrets

# Wait for DB to be reachable (calls entrypoint.sh logic via python)
ExecStartPre=${VENV_PYTHON} - <<'WAITPY'
import os, socket, time, sys
host = os.environ.get("DB_HOST","")
port = int(os.environ.get("DB_PORT","5432"))
if not host:
    print("DB_HOST not set; skipping TCP wait-for-db.")
    sys.exit(0)
deadline = time.time() + 120
while time.time() < deadline:
    try:
        with socket.create_connection((host, port), timeout=3):
            print(f"DB {host}:{port} reachable.")
            sys.exit(0)
    except Exception as e:
        print(f"Waiting for DB {host}:{port}... ({e})")
        time.sleep(2)
print(f"TIMEOUT waiting for DB {host}:{port}.")
sys.exit(1)
WAITPY

# Initialize DB schema (idempotent)
ExecStartPre=${VENV_PYTHON} - <<'INITDB'
import os, sys
sys.path.insert(0, "${APP_DIR}")
# Flask app environment detection via .env already loaded by systemd
from app import init_db, check_db_connection
try:
    check_db_connection()
    init_db()
except Exception as e:
    print(f"DB init warning (non-fatal): {e}", file=sys.stderr)
INITDB

# Start Gunicorn
ExecStart=${VENV_DIR}/bin/gunicorn \
    --workers ${GUNICORN_WORKERS} \
    --bind ${GUNICORN_BIND} \
    --access-logfile ${LOG_DIR}/access.log \
    --error-logfile ${LOG_DIR}/error.log \
    --log-level info \
    app:app

# Robust restart policy
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=5

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR} ${LOG_DIR}
ReadOnlyPaths=/etc/togglemaster

# Logging to journal
StandardOutput=journal
StandardError=journal
SyslogIdentifier=togglemaster

[Install]
WantedBy=multi-user.target
SVC

chmod 644 "${SERVICE_FILE}"
systemctl daemon-reload

echo "  -> Enabling and starting togglemaster.service..."
systemctl enable togglemaster.service
systemctl restart togglemaster.service || {
    echo "WARNING: Service start returned non-zero. Use 'journalctl -u togglemaster -n 100' for details."
}

echo "=========================================="
echo "Bootstrap complete!"
echo "=========================================="
echo ""
echo "Useful commands (run on the EC2 instance via SSH):"
echo "  sudo systemctl status togglemaster"
echo "  sudo journalctl -u togglemaster -f        # live logs"
echo "  tail -f ${LOG_DIR}/access.log"
echo "  sudo /usr/local/bin/togglemaster-fetch-secrets   # re-fetch secrets after rotation"
echo "  curl -s http://localhost:5000/health"
echo ""
echo "Environment file (secrets cached locally, refreshes on service restart):"
echo "  ${ENV_FILE}"
echo ""
