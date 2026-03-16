#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Cost & Resource Waste Audit Tool
    
.DESCRIPTION
    Scans an Azure subscription for wasted or underutilised resources:
      - Unattached managed disks
      - Stopped (deallocated) VMs still incurring storage costs
      - Unused public IP addresses
      - Empty resource groups
      - Unused Network Security Groups
      - Unattached Network Interface Cards
      - Old snapshots (older than 90 days)
      - App Service Plans with no apps
      - Unused Load Balancers
    
    Outputs a colour-coded console summary AND a timestamped HTML report
    you can share with your team or management.

.PARAMETER SubscriptionId
    The Azure Subscription ID to audit. If not provided, uses the current context.

.PARAMETER OutputPath
    Folder path where the HTML report will be saved. Defaults to current directory.

.PARAMETER DaysOldThreshold
    Number of days to consider a snapshot "old". Default is 90.

.PARAMETER ExportCsv
    If specified, also exports findings to a CSV file.

.EXAMPLE
    .\Azure-Cost-Resource-Audit.ps1
    
.EXAMPLE
    .\Azure-Cost-Resource-Audit.ps1 -SubscriptionId "your-sub-id" -OutputPath "C:\Reports" -ExportCsv

.NOTES
    Author:     Maneesha TC
    Version:    1.0
    GitHub:     https://github.com/yourusername/azure-cost-audit
    LinkedIn:   https://linkedin.com/in/maneesha-t-c-23b0b11a1
    
    Requirements:
      - Az PowerShell module  (Install-Module Az -Scope CurrentUser)
      - Reader access on the subscription being audited
      
    To install the Az module:
      Install-Module -Name Az -Repository PSGallery -Force -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [int]$DaysOldThreshold = 90,

    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * ($Text.Length))) -ForegroundColor DarkCyan
}

function Write-Finding {
    param([string]$Text, [string]$Severity = "WARN")
    switch ($Severity) {
        "HIGH"  { Write-Host "  [HIGH]  $Text" -ForegroundColor Red }
        "WARN"  { Write-Host "  [WARN]  $Text" -ForegroundColor Yellow }
        "INFO"  { Write-Host "  [INFO]  $Text" -ForegroundColor White }
        "OK"    { Write-Host "  [ OK ]  $Text" -ForegroundColor Green }
    }
}

function Get-EstimatedMonthlyCost {
    param([string]$ResourceType, [int]$SizeGB = 0)
    # Approximate Azure India (Central India) pricing in INR
    # Update these values from Azure Pricing Calculator for accuracy
    switch ($ResourceType) {
        "ManagedDisk_HDD"    { return [math]::Round($SizeGB * 2.5, 2) }   # ~₹2.5/GB/month P-HDD
        "ManagedDisk_SSD"    { return [math]::Round($SizeGB * 7.0, 2) }   # ~₹7/GB/month P-SSD
        "PublicIP"           { return 280 }                                 # ~₹280/month per static IP
        "Snapshot_per_GB"    { return [math]::Round($SizeGB * 1.8, 2) }   # ~₹1.8/GB/month
        "AppServicePlan_S1"  { return 4500 }                               # ~₹4500/month S1 plan
        "LoadBalancer"       { return 1200 }                               # ~₹1200/month basic LB
        default              { return 0 }
    }
}

# ─────────────────────────────────────────────
#  MODULE CHECK
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     Azure Cost & Resource Audit Tool         ║" -ForegroundColor Cyan
Write-Host "  ║     by Maneesha TC  |  v1.0                  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "  [ERROR] Az module not found." -ForegroundColor Red
    Write-Host "  Run: Install-Module -Name Az -Repository PSGallery -Force -Scope CurrentUser" -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────
#  AUTHENTICATION
# ─────────────────────────────────────────────

Write-Header "Connecting to Azure"

try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "  No active session found. Launching login..." -ForegroundColor Yellow
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Finding "Signed in as: $($context.Account.Id)" "OK"
} catch {
    Write-Host "  [ERROR] Failed to connect to Azure: $_" -ForegroundColor Red
    exit 1
}

if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $context = Get-AzContext
}

$subName = $context.Subscription.Name
$subId   = $context.Subscription.Id
Write-Finding "Subscription: $subName ($subId)" "INFO"
Write-Finding "Audit started: $(Get-Date -Format 'dd-MMM-yyyy HH:mm:ss')" "INFO"

# ─────────────────────────────────────────────
#  INITIALISE FINDINGS COLLECTION
# ─────────────────────────────────────────────

$allFindings = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalEstimatedWaste = 0

function Add-Finding {
    param(
        [string]$Category,
        [string]$ResourceName,
        [string]$ResourceGroup,
        [string]$Location,
        [string]$Detail,
        [string]$Severity,
        [double]$EstimatedMonthlyCostINR = 0,
        [string]$Recommendation
    )
    $script:totalEstimatedWaste += $EstimatedMonthlyCostINR
    $allFindings.Add([PSCustomObject]@{
        Category              = $Category
        ResourceName          = $ResourceName
        ResourceGroup         = $ResourceGroup
        Location              = $Location
        Detail                = $Detail
        Severity              = $Severity
        EstimatedMonthlyINR   = $EstimatedMonthlyCostINR
        Recommendation        = $Recommendation
        AuditTime             = (Get-Date -Format 'dd-MMM-yyyy HH:mm')
    })
}

# ─────────────────────────────────────────────
#  CHECK 1 — UNATTACHED MANAGED DISKS
# ─────────────────────────────────────────────

Write-Header "Check 1/9 — Unattached Managed Disks"

try {
    $disks = Get-AzDisk | Where-Object { $_.DiskState -eq "Unattached" }
    
    if ($disks.Count -eq 0) {
        Write-Finding "No unattached disks found." "OK"
    } else {
        foreach ($disk in $disks) {
            $sku      = $disk.Sku.Name
            $sizeGB   = $disk.DiskSizeGB
            $rType    = if ($sku -like "*Premium*") { "ManagedDisk_SSD" } else { "ManagedDisk_HDD" }
            $cost     = Get-EstimatedMonthlyCost -ResourceType $rType -SizeGB $sizeGB
            $detail   = "$sizeGB GB | SKU: $sku | Created: $($disk.TimeCreated.ToString('dd-MMM-yyyy'))"
            
            Write-Finding "UNATTACHED DISK: $($disk.Name) | $detail | ~₹$cost/month" "HIGH"
            Add-Finding -Category "Unattached Disk" `
                        -ResourceName $disk.Name `
                        -ResourceGroup $disk.ResourceGroupName `
                        -Location $disk.Location `
                        -Detail $detail `
                        -Severity "HIGH" `
                        -EstimatedMonthlyCostINR $cost `
                        -Recommendation "Delete disk or take a snapshot first, then delete. Saves ~₹$cost/month."
        }
    }
} catch {
    Write-Finding "Could not retrieve disks: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 2 — STOPPED (DEALLOCATED) VMs
# ─────────────────────────────────────────────

Write-Header "Check 2/9 — Stopped / Deallocated Virtual Machines"

try {
    $vms = Get-AzVM -Status | Where-Object { $_.PowerState -eq "VM deallocated" }
    
    if ($vms.Count -eq 0) {
        Write-Finding "No deallocated VMs found." "OK"
    } else {
        foreach ($vm in $vms) {
            $detail = "Size: $($vm.HardwareProfile.VmSize) | OS: $($vm.StorageProfile.OsDisk.OsType) | Stopped since: check Activity Log"
            Write-Finding "STOPPED VM: $($vm.Name) | $detail" "WARN"
            Add-Finding -Category "Stopped VM" `
                        -ResourceName $vm.Name `
                        -ResourceGroup $vm.ResourceGroupName `
                        -Location $vm.Location `
                        -Detail $detail `
                        -Severity "WARN" `
                        -EstimatedMonthlyCostINR 0 `
                        -Recommendation "VM compute is free when deallocated but OS disk and attached disks still incur cost. Delete if not needed, or start and review usage."
        }
    }
} catch {
    Write-Finding "Could not retrieve VMs: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 3 — UNUSED PUBLIC IP ADDRESSES
# ─────────────────────────────────────────────

Write-Header "Check 3/9 — Unused Public IP Addresses"

try {
    $pips = Get-AzPublicIpAddress | Where-Object { 
        $_.IpConfiguration -eq $null -and $_.NatGateway -eq $null 
    }
    
    if ($pips.Count -eq 0) {
        Write-Finding "No unused public IPs found." "OK"
    } else {
        foreach ($pip in $pips) {
            $cost   = Get-EstimatedMonthlyCost -ResourceType "PublicIP"
            $detail = "Allocation: $($pip.PublicIpAllocationMethod) | SKU: $($pip.Sku.Name) | IP: $($pip.IpAddress)"
            
            Write-Finding "UNUSED PUBLIC IP: $($pip.Name) | $detail | ~₹$cost/month" "HIGH"
            Add-Finding -Category "Unused Public IP" `
                        -ResourceName $pip.Name `
                        -ResourceGroup $pip.ResourceGroupName `
                        -Location $pip.Location `
                        -Detail $detail `
                        -Severity "HIGH" `
                        -EstimatedMonthlyCostINR $cost `
                        -Recommendation "Delete this public IP if not needed. Static IPs are billed even when unassigned. Saves ~₹$cost/month."
        }
    }
} catch {
    Write-Finding "Could not retrieve public IPs: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 4 — EMPTY RESOURCE GROUPS
# ─────────────────────────────────────────────

Write-Header "Check 4/9 — Empty Resource Groups"

try {
    $rgs      = Get-AzResourceGroup
    $emptyRGs = foreach ($rg in $rgs) {
        $resources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName
        if ($resources.Count -eq 0) { $rg }
    }
    
    if ($emptyRGs.Count -eq 0) {
        Write-Finding "No empty resource groups found." "OK"
    } else {
        foreach ($rg in $emptyRGs) {
            $detail = "Location: $($rg.Location) | Tags: $($rg.Tags.Count) tag(s)"
            Write-Finding "EMPTY RESOURCE GROUP: $($rg.ResourceGroupName) | $detail" "WARN"
            Add-Finding -Category "Empty Resource Group" `
                        -ResourceName $rg.ResourceGroupName `
                        -ResourceGroup $rg.ResourceGroupName `
                        -Location $rg.Location `
                        -Detail $detail `
                        -Severity "WARN" `
                        -EstimatedMonthlyCostINR 0 `
                        -Recommendation "Delete empty resource groups to reduce clutter and avoid accidental resource creation in wrong groups."
        }
    }
} catch {
    Write-Finding "Could not retrieve resource groups: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 5 — UNATTACHED NETWORK INTERFACE CARDS
# ─────────────────────────────────────────────

Write-Header "Check 5/9 — Unattached Network Interface Cards (NICs)"

try {
    $nics = Get-AzNetworkInterface | Where-Object { $_.VirtualMachine -eq $null }
    
    if ($nics.Count -eq 0) {
        Write-Finding "No unattached NICs found." "OK"
    } else {
        foreach ($nic in $nics) {
            $detail = "Private IP: $($nic.IpConfigurations[0].PrivateIpAddress) | Subnet: $($nic.IpConfigurations[0].Subnet.Id.Split('/')[-1])"
            Write-Finding "UNATTACHED NIC: $($nic.Name) | $detail" "WARN"
            Add-Finding -Category "Unattached NIC" `
                        -ResourceName $nic.Name `
                        -ResourceGroup $nic.ResourceGroupName `
                        -Location $nic.Location `
                        -Detail $detail `
                        -Severity "WARN" `
                        -EstimatedMonthlyCostINR 0 `
                        -Recommendation "Delete unattached NICs. They consume IP space and add confusion during network audits."
        }
    }
} catch {
    Write-Finding "Could not retrieve NICs: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 6 — OLD SNAPSHOTS
# ─────────────────────────────────────────────

Write-Header "Check 6/9 — Old Snapshots (>$DaysOldThreshold days)"

try {
    $cutoffDate = (Get-Date).AddDays(-$DaysOldThreshold)
    $snapshots  = Get-AzSnapshot | Where-Object { $_.TimeCreated -lt $cutoffDate }
    
    if ($snapshots.Count -eq 0) {
        Write-Finding "No snapshots older than $DaysOldThreshold days found." "OK"
    } else {
        foreach ($snap in $snapshots) {
            $agedays = [math]::Round(((Get-Date) - $snap.TimeCreated).TotalDays)
            $sizeGB  = $snap.DiskSizeGB
            $cost    = Get-EstimatedMonthlyCost -ResourceType "Snapshot_per_GB" -SizeGB $sizeGB
            $detail  = "$sizeGB GB | Age: $agedays days | Created: $($snap.TimeCreated.ToString('dd-MMM-yyyy'))"
            
            Write-Finding "OLD SNAPSHOT: $($snap.Name) | $detail | ~₹$cost/month" "WARN"
            Add-Finding -Category "Old Snapshot" `
                        -ResourceName $snap.Name `
                        -ResourceGroup $snap.ResourceGroupName `
                        -Location $snap.Location `
                        -Detail $detail `
                        -Severity "WARN" `
                        -EstimatedMonthlyCostINR $cost `
                        -Recommendation "Review if this snapshot is still needed. Snapshots older than $DaysOldThreshold days are often forgotten. Delete to save ~₹$cost/month."
        }
    }
} catch {
    Write-Finding "Could not retrieve snapshots: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 7 — APP SERVICE PLANS WITH NO APPS
# ─────────────────────────────────────────────

Write-Header "Check 7/9 — App Service Plans with No Apps"

try {
    $plans = Get-AzAppServicePlan
    
    foreach ($plan in $plans) {
        $apps = Get-AzWebApp -AppServicePlan $plan.Name -ErrorAction SilentlyContinue
        if ($apps.Count -eq 0 -and $plan.Sku.Tier -ne "Free" -and $plan.Sku.Tier -ne "Shared") {
            $cost   = Get-EstimatedMonthlyCost -ResourceType "AppServicePlan_S1"
            $detail = "SKU: $($plan.Sku.Name) | Tier: $($plan.Sku.Tier) | Workers: $($plan.Sku.Capacity)"
            
            Write-Finding "EMPTY APP SERVICE PLAN: $($plan.Name) | $detail | ~₹$cost/month" "HIGH"
            Add-Finding -Category "Empty App Service Plan" `
                        -ResourceName $plan.Name `
                        -ResourceGroup $plan.ResourceGroupName `
                        -Location $plan.GeoRegion `
                        -Detail $detail `
                        -Severity "HIGH" `
                        -EstimatedMonthlyCostINR $cost `
                        -Recommendation "Delete this App Service Plan — it has no apps but is incurring full compute costs. Saves ~₹$cost/month."
        }
    }
    
    if (($allFindings | Where-Object { $_.Category -eq "Empty App Service Plan" }).Count -eq 0) {
        Write-Finding "All App Service Plans have at least one app." "OK"
    }
} catch {
    Write-Finding "Could not retrieve App Service Plans: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 8 — UNUSED NETWORK SECURITY GROUPS
# ─────────────────────────────────────────────

Write-Header "Check 8/9 — Unused Network Security Groups (NSGs)"

try {
    $nsgs = Get-AzNetworkSecurityGroup | Where-Object {
        ($_.NetworkInterfaces.Count -eq 0) -and ($_.Subnets.Count -eq 0)
    }
    
    if ($nsgs.Count -eq 0) {
        Write-Finding "No unused NSGs found." "OK"
    } else {
        foreach ($nsg in $nsgs) {
            $ruleCount = $nsg.SecurityRules.Count
            $detail    = "Custom rules: $ruleCount | Not attached to any NIC or Subnet"
            
            Write-Finding "UNUSED NSG: $($nsg.Name) | $detail" "WARN"
            Add-Finding -Category "Unused NSG" `
                        -ResourceName $nsg.Name `
                        -ResourceGroup $nsg.ResourceGroupName `
                        -Location $nsg.Location `
                        -Detail $detail `
                        -Severity "WARN" `
                        -EstimatedMonthlyCostINR 0 `
                        -Recommendation "Delete or archive unused NSGs. Stale NSGs create security audit noise and confusion during incident response."
        }
    }
} catch {
    Write-Finding "Could not retrieve NSGs: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CHECK 9 — UNUSED LOAD BALANCERS
# ─────────────────────────────────────────────

Write-Header "Check 9/9 — Load Balancers with Empty Backend Pools"

try {
    $lbs = Get-AzLoadBalancer
    
    foreach ($lb in $lbs) {
        $hasBackend = $false
        foreach ($pool in $lb.BackendAddressPools) {
            $poolDetail = Get-AzLoadBalancerBackendAddressPool -ResourceGroupName $lb.ResourceGroupName `
                            -LoadBalancerName $lb.Name -Name $pool.Name -ErrorAction SilentlyContinue
            if ($poolDetail.BackendIPConfigurations.Count -gt 0) {
                $hasBackend = $true
                break
            }
        }
        
        if (-not $hasBackend -and $lb.Sku.Name -ne "Basic") {
            $cost   = Get-EstimatedMonthlyCost -ResourceType "LoadBalancer"
            $detail = "SKU: $($lb.Sku.Name) | Backend pools: $($lb.BackendAddressPools.Count) (all empty)"
            
            Write-Finding "EMPTY LOAD BALANCER: $($lb.Name) | $detail | ~₹$cost/month" "HIGH"
            Add-Finding -Category "Empty Load Balancer" `
                        -ResourceName $lb.Name `
                        -ResourceGroup $lb.ResourceGroupName `
                        -Location $lb.Location `
                        -Detail $detail `
                        -Severity "HIGH" `
                        -EstimatedMonthlyCostINR $cost `
                        -Recommendation "Load balancer has no backend VMs. Delete if decommissioned. Saves ~₹$cost/month."
        }
    }
    
    if (($allFindings | Where-Object { $_.Category -eq "Empty Load Balancer" }).Count -eq 0) {
        Write-Finding "No load balancers with empty backend pools found." "OK"
    }
} catch {
    Write-Finding "Could not retrieve load balancers: $_" "WARN"
}

# ─────────────────────────────────────────────
#  CONSOLE SUMMARY
# ─────────────────────────────────────────────

Write-Host ""
Write-Host "  ════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AUDIT SUMMARY" -ForegroundColor Cyan
Write-Host "  ════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$highCount   = ($allFindings | Where-Object { $_.Severity -eq "HIGH" }).Count
$warnCount   = ($allFindings | Where-Object { $_.Severity -eq "WARN" }).Count
$totalCount  = $allFindings.Count

Write-Host "  Total findings       : $totalCount" -ForegroundColor White
Write-Host "  High severity        : $highCount"  -ForegroundColor Red
Write-Host "  Warning              : $warnCount"  -ForegroundColor Yellow
Write-Host ""
Write-Host "  Estimated monthly waste : ₹$([math]::Round($totalEstimatedWaste, 0).ToString('N0'))" -ForegroundColor $(if ($totalEstimatedWaste -gt 10000) { "Red" } elseif ($totalEstimatedWaste -gt 2000) { "Yellow" } else { "Green" })
Write-Host "  Estimated annual waste  : ₹$([math]::Round($totalEstimatedWaste * 12, 0).ToString('N0'))" -ForegroundColor $(if ($totalEstimatedWaste -gt 10000) { "Red" } elseif ($totalEstimatedWaste -gt 2000) { "Yellow" } else { "Green" })
Write-Host ""

# ─────────────────────────────────────────────
#  CSV EXPORT
# ─────────────────────────────────────────────

if ($ExportCsv) {
    $csvPath = Join-Path $OutputPath "Azure-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    $allFindings | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "  CSV exported : $csvPath" -ForegroundColor Green
}

# ─────────────────────────────────────────────
#  HTML REPORT GENERATION
# ─────────────────────────────────────────────

Write-Header "Generating HTML Report"

$reportDate   = Get-Date -Format "dd MMM yyyy, HH:mm"
$reportFile   = Join-Path $OutputPath "Azure-Cost-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm').html"

$severityColour = @{
    "HIGH" = "#fee2e2"
    "WARN" = "#fef9c3"
    "INFO" = "#eff6ff"
    "OK"   = "#dcfce7"
}
$severityText = @{
    "HIGH" = "#991b1b"
    "WARN" = "#854d0e"
    "INFO" = "#1e40af"
    "OK"   = "#166534"
}

$tableRows = foreach ($f in $allFindings) {
    $bgColor   = $severityColour[$f.Severity]
    $textColor = $severityText[$f.Severity]
    $costCell  = if ($f.EstimatedMonthlyINR -gt 0) { "₹$([math]::Round($f.EstimatedMonthlyINR,0).ToString('N0'))" } else { "—" }
    @"
    <tr>
      <td><span style='background:$bgColor;color:$textColor;padding:2px 8px;border-radius:4px;font-size:12px;font-weight:600;'>$($f.Severity)</span></td>
      <td><strong>$($f.Category)</strong></td>
      <td>$($f.ResourceName)</td>
      <td>$($f.ResourceGroup)</td>
      <td>$($f.Location)</td>
      <td style='font-size:12px;color:#555;'>$($f.Detail)</td>
      <td style='color:#dc2626;font-weight:600;'>$costCell</td>
      <td style='font-size:12px;color:#374151;'>$($f.Recommendation)</td>
    </tr>
"@
}

$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Azure Cost Audit Report</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f8fafc; color: #1e293b; }
    .header { background: #1e3a5f; color: white; padding: 2rem 2.5rem; }
    .header h1 { font-size: 22px; font-weight: 600; margin-bottom: 6px; }
    .header p  { font-size: 14px; opacity: 0.75; }
    .summary   { display: flex; gap: 16px; padding: 1.5rem 2.5rem; background: white; border-bottom: 1px solid #e2e8f0; flex-wrap: wrap; }
    .stat      { background: #f1f5f9; border-radius: 8px; padding: 12px 20px; min-width: 160px; }
    .stat-num  { font-size: 26px; font-weight: 700; }
    .stat-lbl  { font-size: 12px; color: #64748b; margin-top: 2px; }
    .content   { padding: 2rem 2.5rem; }
    table      { width: 100%; border-collapse: collapse; background: white; border-radius: 10px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.08); font-size: 13px; }
    th         { background: #1e3a5f; color: white; padding: 10px 12px; text-align: left; font-weight: 500; font-size: 12px; }
    td         { padding: 10px 12px; border-bottom: 1px solid #f1f5f9; vertical-align: top; }
    tr:last-child td { border-bottom: none; }
    tr:hover td { background: #f8fafc; }
    .footer    { text-align: center; padding: 1.5rem; font-size: 12px; color: #94a3b8; }
    .no-findings { text-align: center; padding: 3rem; color: #64748b; font-size: 15px; }
  </style>
</head>
<body>

<div class="header">
  <h1>Azure Cost &amp; Resource Waste Audit</h1>
  <p>Subscription: $subName &nbsp;|&nbsp; Generated: $reportDate &nbsp;|&nbsp; Audited by: Maneesha TC</p>
</div>

<div class="summary">
  <div class="stat">
    <div class="stat-num" style="color:#dc2626;">$highCount</div>
    <div class="stat-lbl">High severity findings</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color:#d97706;">$warnCount</div>
    <div class="stat-lbl">Warnings</div>
  </div>
  <div class="stat">
    <div class="stat-num">$totalCount</div>
    <div class="stat-lbl">Total findings</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color:#dc2626;">₹$([math]::Round($totalEstimatedWaste, 0).ToString('N0'))</div>
    <div class="stat-lbl">Estimated monthly waste (INR)</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color:#dc2626;">₹$([math]::Round($totalEstimatedWaste * 12, 0).ToString('N0'))</div>
    <div class="stat-lbl">Estimated annual waste (INR)</div>
  </div>
</div>

<div class="content">
  $(if ($allFindings.Count -eq 0) {
    '<div class="no-findings">No waste findings detected. Your subscription looks clean!</div>'
  } else {
    @"
  <table>
    <thead>
      <tr>
        <th>Severity</th>
        <th>Category</th>
        <th>Resource Name</th>
        <th>Resource Group</th>
        <th>Location</th>
        <th>Detail</th>
        <th>Est. Monthly Cost</th>
        <th>Recommendation</th>
      </tr>
    </thead>
    <tbody>
      $($tableRows -join "`n")
    </tbody>
  </table>
"@
  })
</div>

<div class="footer">
  Azure Cost &amp; Resource Audit Tool by Maneesha TC &nbsp;|&nbsp;
  <a href="https://github.com/yourusername/azure-cost-audit" style="color:#3b82f6;">GitHub</a> &nbsp;|&nbsp;
  <a href="https://linkedin.com/in/maneesha-t-c-23b0b11a1" style="color:#3b82f6;">LinkedIn</a>
</div>

</body>
</html>
"@

$htmlContent | Out-File -FilePath $reportFile -Encoding UTF8

Write-Host ""
Write-Host "  HTML Report saved : $reportFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Tip: Open the HTML file in any browser to share with your manager or team." -ForegroundColor Cyan
Write-Host ""
