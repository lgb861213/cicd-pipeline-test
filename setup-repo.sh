#!/bin/bash
# Run inside the local cicd-pipeline-test repository
set -e

mkdir -p app .github/workflows

# ---------- Web page source (edit this file to simulate a release) ----------
tee app/index.html > /dev/null <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>CI/CD Demo</title>
  <style>
    body { font-family: Arial, sans-serif; text-align: center; margin-top: 80px; background: #f4f8fb; }
    .card { display: inline-block; padding: 32px 48px; background: #fff; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,.08); }
    h1 { color: #1F4E79; }
    .meta { color: #666; font-size: 14px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello from GitHub Actions - Release v1</h1>
    <p>This page is deployed to an existing EC2 instance via AWS Systems Manager.</p>
    <p class="meta">Version: __VERSION__ | Commit: __COMMIT__ | Deployed at: __TIME__</p>
  </div>
</body>
</html>
EOF

# ---------- Workflow ----------
tee .github/workflows/cicd.yml > /dev/null <<'EOF'
name: Deploy Web to Existing EC2 with Approval

on:
  push:
    branches: [main]
    paths:
      - "app/**"
      - ".github/workflows/cicd.yml"
  workflow_dispatch:

permissions:
  id-token: write   # Required for OIDC
  contents: read

concurrency:
  group: deploy-prod
  cancel-in-progress: false

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.meta.outputs.version }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set release metadata
        id: meta
        run: echo "version=v${GITHUB_RUN_NUMBER}" >> "$GITHUB_OUTPUT"

      - name: Render page
        run: |
          mkdir -p dist
          sed -e "s/__VERSION__/${{ steps.meta.outputs.version }}/" \
              -e "s/__COMMIT__/${GITHUB_SHA::7}/" \
              -e "s/__TIME__/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" \
              app/index.html > dist/index.html

      - name: Basic test
        run: |
          grep -q "<html" dist/index.html
          ! grep -q "__VERSION__" dist/index.html
          echo "Page rendered OK"

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: web
          path: dist/index.html

  deploy-to-ec2:
    needs: build-and-test
    runs-on: ubuntu-latest
    environment: prod   # Reviewers + branch rules + env secrets/vars
    env:
      AWS_REGION: ${{ vars.AWS_REGION }}
      APP_TAG: ${{ vars.APP_TAG || 'cicd-web' }}
      VERSION: ${{ needs.build-and-test.outputs.version }}
    steps:
      - name: Download artifact
        uses: actions/download-artifact@v4
        with:
          name: web
          path: dist

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
          retry-max-attempts: 2

      - name: Verify identity
        run: aws sts get-caller-identity

      - name: Locate target instance
        id: target
        run: |
          read -r ID IP <<< "$(aws ec2 describe-instances \
            --filters "Name=tag:App,Values=$APP_TAG" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' --output text)"
          if [ -z "$ID" ] || [ "$ID" = "None" ]; then echo "No running instance with App=$APP_TAG"; exit 1; fi
          echo "Instance: $ID  PublicIp: $IP"
          echo "id=$ID" >> "$GITHUB_OUTPUT"
          echo "ip=$IP" >> "$GITHUB_OUTPUT"

      - name: Deploy page via SSM Run Command
        id: deploy
        run: |
          B64=$(base64 -w0 dist/index.html)
          jq -n --arg b64 "$B64" '{commands: [
            "set -e",
            "TS=$(date +%Y%m%d%H%M%S)",
            "cp /usr/share/nginx/html/index.html /usr/share/nginx/html/index.html.$TS.bak || true",
            ("echo " + $b64 + " | base64 -d > /tmp/index.html"),
            "install -m 644 /tmp/index.html /usr/share/nginx/html/index.html",
            "systemctl reload nginx || systemctl restart nginx",
            "echo Deployed"
          ]}' > params.json
          CMD_ID=$(aws ssm send-command \
            --instance-ids "${{ steps.target.outputs.id }}" \
            --document-name AWS-RunShellScript \
            --comment "Deploy $VERSION from GitHub Actions run $GITHUB_RUN_ID" \
            --parameters file://params.json \
            --query 'Command.CommandId' --output text)
          echo "CommandId: $CMD_ID"
          echo "cmd=$CMD_ID" >> "$GITHUB_OUTPUT"

      - name: Wait for command result
        run: |
          aws ssm wait command-executed \
            --command-id "${{ steps.deploy.outputs.cmd }}" \
            --instance-id "${{ steps.target.outputs.id }}" || true
          aws ssm get-command-invocation \
            --command-id "${{ steps.deploy.outputs.cmd }}" \
            --instance-id "${{ steps.target.outputs.id }}" \
            --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' --output json
          STATUS=$(aws ssm get-command-invocation \
            --command-id "${{ steps.deploy.outputs.cmd }}" \
            --instance-id "${{ steps.target.outputs.id }}" \
            --query Status --output text)
          [ "$STATUS" = "Success" ] || { echo "Deployment failed: $STATUS"; exit 1; }

      - name: Smoke test
        run: |
          URL="http://${{ steps.target.outputs.ip }}/"
          for i in 1 2 3 4 5; do
            if curl -fsS "$URL" | grep -q "Version: $VERSION"; then
              echo "Smoke test passed: $URL shows $VERSION"; exit 0
            fi
            sleep 5
          done
          echo "Smoke test failed: $URL does not show $VERSION"; exit 1
EOF

echo "Files written: app/index.html, .github/workflows/cicd.yml"
