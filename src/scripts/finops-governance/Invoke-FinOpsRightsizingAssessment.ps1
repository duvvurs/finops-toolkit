#Requires -Module Az.Compute, Az.Monitor, Az.Accounts
<#
.SYNOPSIS
    Identifies over-provisioned Azure VMs and recommends right-sized SKUs
    
.DESCRIPTION
    Production pattern for VM rightsizing assessment. Analyses CPU utilisation
    over a configurable window and recommends smaller SKUs from the same family.
    Used to deliver £624K annualised savings across client engagements.
    
    Methodology:
    - CPU avg < 15% AND max < 30% over analysis window = rightsize candidate
    - Recommends next-smaller SKU in same family to maintain compatibility
    - Excludes burstable B-series (expected to run low CPU)
    - Flags production VMs separately for priority actioning
    
.EXAMPLE
    .\Invoke-FinOpsRightsizingAssessment.ps1 -SubscriptionId "sub1" -CpuThreshold 15 -DaysBack 14
    .\Invoke-FinOpsRightsizingAssessment.ps1 -SubscriptionId "sub1" -CpuThreshold 20 -DaysBack 30 -OutputPath ".\rightsizing.csv"
    
.NOTES
    Author: Duvvur Sai Krishna
    Derived from production rightsizing initiatives across European enterprise clients
#>

param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    
    [Parameter()]
    [int]$CpuThreshold = 15,
    
    [Parameter()]
    [int]$MaxCpuThreshold = 30,
    
    [Parameter()]
    [int]$DaysBack = 14,
    
    [Parameter()]
    [string]$OutputPath = ".\rightsizing-$(Get-Date -Format 'yyyy-MM-dd').csv"
)

$ErrorActionPreference = 'Continue'
if (-not (Get-AzContext)) { Connect-AzAccount -Identity }

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# SKU rightsize mapping (current → recommended smaller)
$SkuMap = @{
    'Standard_D4s_v5'  = 'Standard_D2s_v5'
    'Standard_D8s_v5'  = 'Standard_D4s_v5'
    'Standard_D16s_v5' = 'Standard_D8s_v5'
    'Standard_D32s_v5' = 'Standard_D16s_v5'
    'Standard_E4s_v5'  = 'Standard_E2s_v5'
    'Standard_E8s_v5'  = 'Standard_E4s_v5'
    'Standard_E16s_v5' = 'Standard_E8s_v5'
    'Standard_E32s_v5' = 'Standard_E16s_v5'
    'Standard_F4s_v2'  = 'Standard_F2s_v2'
    'Standard_F8s_v2'  = 'Standard_F4s_v2'
    'Standard_F16s_v2' = 'Standard_F8s_v2'
    'Standard_D4s_v4'  = 'Standard_D2s_v4'
    'Standard_D8s_v4'  = 'Standard_D4s_v4'
    'Standard_E4s_v3'  = 'Standard_E2s_v3'
    'Standard_E8s_v3'  = 'Standard_E4s_v3'
}

# Pricing estimates (GBP/month, approximate)
$SkuPricing = @{
    'Standard_D2s_v5'  = 52;  'Standard_D4s_v5'  = 105
    'Standard_D8s_v5'  = 210; 'Standard_D16s_v5' = 420; 'Standard_D32s_v5' = 840
    'Standard_E2s_v5'  = 105; 'Standard_E4s_v5'  = 210
    'Standard_E8s_v5'  = 420; 'Standard_E16s_v5' = 840; 'Standard_E32s_v5' = 1680
    'Standard_F2s_v2'  = 88;  'Standard_F4s_v2'  = 176
    'Standard_F8s_v2'  = 352; 'Standard_F16s_v2' = 704
    'Standard_D2s_v4'  = 70;  'Standard_D4s_v4'  = 140; 'Standard_D8s_v4'  = 280
    'Standard_E2s_v3'  = 105; 'Standard_E4s_v3'  = 210; 'Standard_E8s_v3'  = 420
}

Write-Host "`n=== RIGHTSIZING ASSESSMENT ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId"
Write-Host "Threshold: Avg CPU < $CpuThreshold% AND Max CPU < $MaxCpuThreshold%"
Write-Host "Window: $DaysBack days"

$VMs = Get-AzVM -Status
$Results = @()
$TotalSavings = 0

foreach ($VM in $VMs) {
    # Skip B-series (burstable, expected to run low CPU)
    if ($VM.HardwareProfile.VmSize -match 'Standard_B') { continue }
    
    # Skip deallocated VMs
    if ($VM.PowerState -ne 'VM running') { continue }
    
    $CurrentSKU = $VM.HardwareProfile.VmSize
    $RecommendedSKU = $SkuMap[$CurrentSKU]
    
    # Only assess if we have a recommendation
    if (-not $RecommendedSKU) { continue }
    
    # Get CPU metrics
    $StartTime = (Get-Date).AddDays(-$DaysBack)
    $EndTime = Get-Date
    
    try {
        $Metrics = Get-AzMetric -ResourceId $VM.Id `
            -MetricName "Percentage CPU" `
            -TimeGrain (New-TimeSpan -Hours 1) `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -WarningAction SilentlyContinue
        
        if ($Metrics.Data) {
            $AvgCpu = ($Metrics.Data | Measure-Object -Property Average -Average).Average
            $MaxCpu = ($Metrics.Data | Measure-Object -Property Maximum -Maximum).Maximum
            
            $AvgCpuRounded = [math]::Round($AvgCpu, 1)
            $MaxCpuRounded = [math]::Round($MaxCpu, 1)
            
            if ($AvgCpu -lt $CpuThreshold -and $MaxCpu -lt $MaxCpuThreshold) {
                $CurrentCost = $SkuPricing[$CurrentSKU]
                $NewCost = $SkuPricing[$RecommendedSKU]
                $Savings = if ($CurrentCost -and $NewCost) { $CurrentCost - $NewCost } else { 0 }
                $TotalSavings += $Savings
                
                $Environment = if ($VM.Tags['environment']) { $VM.Tags['environment'] } else { 'unknown' }
                $CostCentre = if ($VM.Tags['cost-centre']) { $VM.Tags['cost-centre'] } else { 'untagged' }
                
                $Results += [PSCustomObject]@{
                    VMName         = $VM.Name
                    ResourceGroup  = $VM.ResourceGroupName
                    CurrentSKU     = $CurrentSKU
                    RecommendedSKU = $RecommendedSKU
                    AvgCPU_pct     = $AvgCpuRounded
                    MaxCPU_pct     = $MaxCpuRounded
                    CurrentCostGBPMonth = if ($CurrentCost) { "£$CurrentCost" } else { 'N/A' }
                    NewCostGBPMonth     = if ($NewCost) { "£$NewCost" } else { 'N/A' }
                    SavingsGBPMonth     = if ($Savings) { "£$Savings" } else { 'N/A' }
                    Environment    = $Environment
                    CostCentre     = $CostCentre
                }
            }
        }
    }
    catch {
        # Skip VMs where metrics aren't available (recently created, no agent, etc.)
    }
}

# Output results
if ($Results) {
    $Results | Format-Table -AutoSize
    $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    
    $AnnualSavings = $TotalSavings * 12
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Green
    Write-Host "Rightsize candidates: $($Results.Count) VMs"
    Write-Host "Monthly savings potential: £$TotalSavings"
    Write-Host "Annualised savings potential: £$AnnualSavings"
    Write-Host "Report saved: $OutputPath"
}
else {
    Write-Host "`nNo rightsize candidates found above threshold." -ForegroundColor Yellow
}
