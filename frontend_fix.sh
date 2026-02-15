echo "📦 FLATTENING REPO & UPDATING PIPELINES..."

# 1. Move all files from subfolder to root (preserving Git history)
# We check if the folder exists first to avoid errors if you ran this already
if [ -d "CampusOne-Web" ]; then
    echo "   🚚 Moving files to root..."
    git mv CampusOne-Web/* . 2>/dev/null
    # Move hidden files (like .env or .eslintrc) carefully
    for file in CampusOne-Web/.*; do
        if [[ "$file" != "CampusOne-Web/." && "$file" != "CampusOne-Web/.." ]]; then
            git mv "$file" . 2>/dev/null
        fi
    done
    # Remove the now-empty directory
    rmdir CampusOne-Web 2>/dev/null
else
    echo "   ℹ️  Files already moved (or folder not found)."
fi

# 2. Update 'front-end-workflow.yml' 
# CHANGE: It now runs in '.' (root) instead of 'inputs.system-dir'
echo "   📝 Updating front-end-workflow.yml to run in root..."
cat <<EOF > .github/workflows/front-end-workflow.yml
name: Frontend Web CI/CD Pipeline

on:
  workflow_call:
    inputs:
      system-dir:
        required: true
        type: string
        description: 'System Name (Used for Artifacts/Sonar, NOT path)'
      sonar-project-key:
        required: true
        type: string
        description: 'SonarCloud project key'
      sonar-organization:
        required: false
        type: string
        default: 'implementsprint'
        description: 'SonarCloud organization'
      coverage-threshold:
        required: false
        type: number
        default: 80
        description: 'Minimum code coverage percentage required'
    secrets:
      SONAR_TOKEN:
        required: false

jobs:
  # ── Stage 1: Governance Checks ──────────────────────────────────
  web-governance:
    name: Web — Governance Checks
    uses: ./.github/workflows/governance-check.yml
    with:
      working-directory: '.'   # 👈 NOW RUNS IN ROOT
      test-command: 'npx vitest run --coverage --reporter=verbose'
      coverage-threshold: \${{ inputs.coverage-threshold }}

  # ── Stage 2: SonarCloud Quality Gate ───────────────────────────
  web-sonarcloud:
    name: Web — SonarCloud Analysis
    needs: web-governance
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Download Coverage Report
        uses: actions/download-artifact@v4
        with:
          name: \${{ inputs.system-dir }}-coverage
          path: coverage  # 👈 Save directly to root coverage folder

      - name: Run SonarCloud Scan
        uses: SonarSource/sonarqube-scan-action@v5.0.0
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          SONAR_TOKEN: \${{ secrets.SONAR_TOKEN }}
        with:
          projectBaseDir: .   # 👈 NOW RUNS IN ROOT
          args: >
            -Dsonar.organization=\${{ inputs.sonar-organization }}
            -Dsonar.projectKey=\${{ inputs.sonar-project-key }}
            -Dsonar.sources=src
            -Dsonar.tests=src
            -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info

  # ── Stage 3: Build Web Application ─────────────────────────────
  web-build:
    name: Web — Build
    needs: web-sonarcloud
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: .   # 👈 NOW RUNS IN ROOT
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install Dependencies
        run: npm ci

      - name: Fix Vite Entry Point
        run: |
            if [ -f "public/index.html" ] && [ ! -f "index.html" ]; then
                mv public/index.html .
            fi

      - name: Build Application
        run: npm run build

      - name: Upload Build Artifact
        uses: actions/upload-artifact@v4
        with:
          name: \${{ inputs.system-dir }}-web-build
          path: dist  # 👈 Dist is now in root
          retention-days: 14
EOF

# 3. Update 'master-pipeline.yml' 
# We keep system-dir as "CampusOne-Web" so your artifacts have nice names,
# even though the files are now in the root.
echo "   📝 Ensuring master-pipeline.yml has correct permissions..."
cat <<EOF > .github/workflows/master-pipeline.yml
name: Master Pipeline Orchestrator

on:
  push:
    branches: ['**']
  pull_request:
    branches: [main, develop]

permissions:
  contents: read
  packages: write

concurrency:
  group: master-pipeline-\${{ github.ref }}
  cancel-in-progress: true

jobs:
  # ── Stage 1: CampusOne-Web Pipeline ─────────────────────────────
  campusone-web:
    name: CampusOne-Web Pipeline
    uses: ./.github/workflows/front-end-workflow.yml
    with:
      system-dir: CampusOne-Web  # Used for Naming only
      sonar-project-key: Tribe1-Frontend_CampusOne-Web
    secrets: inherit

  # ── Stage 2: Deploy to Staging ──────────────────────────────────
  deploy-staging-campusone-web:
    name: Staging — CampusOne-Web
    needs: campusone-web
    if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/develop'
    uses: ./.github/workflows/deploy-staging.yml
    with:
      system-dir: CampusOne-Web
      app-type: web
      artifact-name: CampusOne-Web-web-build
    secrets: inherit

  # ── Stage 3: Pipeline Summary ───────────────────────────────────
  pipeline-summary:
    name: Pipeline Summary
    needs: campusone-web
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: Pipeline Results
        run: |
          echo "╔══════════════════════════════════════════════╗"
          echo "║        MASTER PIPELINE SUMMARY               ║"
          echo "╠══════════════════════════════════════════════╣"
          echo "║ Branch:   \${{ github.ref_name }}"
          echo "║ Commit:   \${{ github.sha }}"
          echo "║ Actor:    \${{ github.actor }}"
          echo "╠══════════════════════════════════════════════╣"
          echo "║ CampusOne-Web:     \${{ needs.campusone-web.result }}"
          echo "╚══════════════════════════════════════════════╝"

          if [[ "\${{ needs.campusone-web.result }}" == "failure" ]]; then
            echo "❌ Pipeline failed!"
            exit 1
          fi
          echo "✅ Pipeline completed successfully!"
EOF

# 4. Commit and Push
git add .
git commit -m "refactor: flatten file structure (moved CampusOne-Web to root)"
git push origin main

echo "✅ DONE! Files moved and pipelines updated."