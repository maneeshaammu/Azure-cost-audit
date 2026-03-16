# Azure Cost & Resource Waste Audit Tool

> A PowerShell script that scans your Azure subscription for wasted resources and generates a clean HTML report with estimated monthly cost savings.

Built from 4+ years of real enterprise Azure operations experience — this is the audit I wish existed on day one.

---

## What it finds

| Check | What it catches |
|---|---|
| Unattached managed disks | Disks left behind after VM deletions — silently billing you |
| Stopped VMs | Deallocated VMs whose attached disks are still incurring cost |
| Unused public IPs | Static IPs not assigned to anything — billed every month |
| Empty resource groups | Leftover groups from old projects |
| Unattached NICs | Network cards with no VM attached |
| Old snapshots | Snapshots older than 90 days (configurable) |
| Empty App Service Plans | Plans with no apps still running at full compute cost |
| Unused NSGs | Security groups attached to nothing — clutter and audit noise |
| Load balancers with empty pools | LBs with no backend VMs still on the bill |

---

## Output

**Console** — colour-coded findings with severity (HIGH / WARN) and estimated monthly INR cost per resource.

**HTML report** — clean, shareable report with summary cards showing total estimated monthly and annual waste. Open in any browser, send to your manager.

**CSV export** — optional, for importing into Excel or ticketing systems.

---

## Quick start

### Prerequisites

```powershell
# Install the Az module (one time only)
Install-Module -Name Az -Repository PSGallery -Force -Scope CurrentUser
```

You need **Reader** access on the subscription you want to audit. No write permissions required.

### Run the audit

```powershell
# Audit your current subscription
.\Azure-Cost-Resource-Audit.ps1

# Audit a specific subscription
.\Azure-Cost-Resource-Audit.ps1 -SubscriptionId "your-subscription-id"

# Save report to a specific folder + export CSV
.\Azure-Cost-Resource-Audit.ps1 -OutputPath "C:\AzureReports" -ExportCsv

# Change the snapshot age threshold (default 90 days)
.\Azure-Cost-Resource-Audit.ps1 -DaysOldThreshold 60
```

---

## Example output

```
  ╔══════════════════════════════════════════════╗
  ║     Azure Cost & Resource Audit Tool         ║
  ║     by Maneesha TC  |  v1.0                  ║
  ╚══════════════════════════════════════════════╝

  Check 1/9 — Unattached Managed Disks
  ──────────────────────────────────────
  [HIGH]  UNATTACHED DISK: prod-backup-disk-01 | 512 GB | SKU: Premium_LRS | ~₹3,584/month
  [HIGH]  UNATTACHED DISK: old-data-disk-dev | 128 GB | SKU: Standard_LRS | ~₹320/month

  Check 3/9 — Unused Public IP Addresses
  ────────────────────────────────────────
  [HIGH]  UNUSED PUBLIC IP: pip-old-gateway | Allocation: Static | ~₹280/month

  ════════════════════════════════════════════════
  AUDIT SUMMARY
  ════════════════════════════════════════════════

  Total findings       : 7
  High severity        : 4
  Warning              : 3

  Estimated monthly waste : ₹4,184
  Estimated annual waste  : ₹50,208

  HTML Report saved : C:\Reports\Azure-Cost-Audit-20250315-1430.html
```

---

## Cost estimates

Pricing is based on approximate **Azure Central India** region rates in INR. These are estimates — your actual savings will vary based on disk SKUs, VM sizes, and your Azure agreement pricing.

To update pricing for your region, edit the `Get-EstimatedMonthlyCost` function at the top of the script and refer to the [Azure Pricing Calculator](https://azure.microsoft.com/en-in/pricing/calculator/).

---

## Who should use this

- Cloud operations engineers doing monthly cost reviews
- Azure administrators preparing for FinOps conversations
- Infrastructure teams before subscription billing reviews
- Anyone who has inherited an Azure environment and needs to understand what's in it

---

## Roadmap

- [ ] Azure Advisor integration for additional recommendations
- [ ] Idle/low-utilisation VM detection via Azure Monitor metrics
- [ ] Multi-subscription scan support
- [ ] Email report delivery via SendGrid
- [ ] Teams/Slack webhook notification on HIGH findings

---

## Contributing

Found a resource type that should be checked? Open an issue or submit a PR. All contributions welcome.

---

## Author

**Maneesha TC** — Cloud Infrastructure Engineer  
[LinkedIn](https://linkedin.com/in/maneesha-t-c-23b0b11a1) · [GitHub](https://github.com/yourusername)

---

## License

MIT — free to use, modify, and share.
