# GitHub Copilot Instructions — Azure Terraform IaC

You are assisting in an **Azure Infrastructure-as-Code** repository. The primary
workload is **Terraform targeting Azure**, with supporting **PowerShell**, **Azure
CLI** automation, **Azure Arc onboarding** scripts, and optional **Bicep**.

## Project context
- Cloud: **Microsoft Azure** only.
- Primary IaC: **Terraform** (providers: `azurerm`, `azuread`, `azapi`, `random`, `time`).
- Patterns: **Azure Cloud Adoption Framework (CAF)** and **Well-Architected Framework (WAF)**.
- Scenarios include **Azure Arc evaluation** on Azure VMs and **Windows Server** VMs.

## How to write code here
- Prefer **Terraform** for infrastructure; use **Bicep only** where a component
  cannot be done reliably in Terraform, and say so explicitly.
- Separate configuration from logic: `variables.tf`, `locals.tf`, `main.tf`,
  `outputs.tf`, `providers.tf`, `versions.tf`.
- Use `for_each`/maps over copy-pasted resources. Drive multiple similar
  resources from a single configuration map.
- Pin provider and Terraform versions with sensible constraints (`~>`).
- Follow **CAF naming**: `<type>-<workload>-<env>-<region>-<instance>` and
  apply consistent **tags** to every resource.
- Default to **least privilege**, **private networking**, and **no public IPs**
  unless a variable explicitly opts in (and then restrict source CIDRs).

## Security rules (non-negotiable)
- **Never hard-code** secrets, passwords, service principal secrets, tenant IDs,
  or subscription IDs. Use variables marked `sensitive = true`, environment
  variables (`ARM_*`), or Key Vault references.
- Never write secrets into outputs, logs, comments, or committed `*.tfvars`.
- Remind users that **Terraform state may contain secrets**; recommend a secured
  remote backend (Azure Storage) for shared use.
- Prefer auth via `az login`, **Managed Identity**, **Service Principal**, or
  **GitHub OIDC** (`ARM_USE_OIDC=true`) — never embedded credentials.

## Cost & operational defaults
- This repo favors **low-cost, temporary demo** infrastructure: smallest viable
  VM sizes, Standard HDD where acceptable, no Bastion/Firewall/NAT/LB by default.
- Add auto-shutdown and clear teardown (`terraform destroy`) guidance.

## Style
- Comment the **why** for security, cost, reliability, and operational choices.
- Keep modules small and composable; avoid over-engineering demos.
- After edits, suggest: `terraform fmt`, `terraform validate`, `terraform plan`.
