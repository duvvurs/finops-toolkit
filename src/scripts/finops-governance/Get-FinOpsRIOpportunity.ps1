#Requires -Module Az.Consumption, Az.Compute, Az.Accounts
<#
.SYNOPSIS
    Analyzes On-Demand VM usage and identifies Reserved Instance / Savings Plan opportunities
    
.DESCRIPTION
    Production pattern for RI/SP coverage gap analysis. Identifies VMs running On-Demand
    in production that would benefit from commitment-based pricing.
    
    Methodology:
    1. Find all production VMs (by tag or naming convention)
    2. Filter to On-Demand pricing model
    3. Group by VM size to identify RI purchase candidates
    4. Calculate estimated savings using 1-year and 3-year RI pricing
    5. Recommend RI for stable workloads, SP for variable ones
    
.EXAMPLE
    .\Get-FinOpsRIOpportunity.ps1 -SubscriptionId "sub1" -Environment "prod"
    
.NOTES
    Author: Duvvur Sai Krishna
#>

param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    
    [Parameter()]
    [string]$Environment = 'prod',
    
    [Parameter()]
    [ValidateSet('1-year', '3-year')]
    [string]$Term = '1-year'
)

if (-not (Get-AzContext)) { Connect-AzAccount -Identity }
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# RI discount estimates (approximate, varies by region)
$Discounts = @{
    '1-year' = @{ Upfront = 0.38; Monthly = 0.33 }
    '3-year' = @{ Upfront = 0.52; Monthly = 0.48 }
}

# Approximate on-demand pricing (GBP/month)
$OnDemandPricing = @{
    'Standard_B2s' = 25; 'Standard_B2ms' = 50
    'Standard_D2s_v5' = 70; 'Standard_D4s_v5' = 140; 'Standard_D8s_v5' = 280
    'Standard_D16s_v5' = 560; 'Standard_D32s_v5' = 1120
    'Standard_E2s_v5' = 105; 'Standard_E4s_v5' = 210; 'Standard_E8s_v5' = 420
    'Standard_E16s_v5' = 840; 'Standard_E32s_v5' = 1680
    'Standard_F2s_v2' = 88; 'Standard_F4s_v2' = 176; 'Standard_F8s_v2' = 352
}

Write-Host "`n=== RI/SP OPPORTUNITY ANALYSIS ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId"
Write-Host "Environment: $Environment"
Write-Host "Term: $Term"

$VMs = Get-AzVM

# Filter to target environment
$TargetVMs = $VMs | Where-Object {
    ($_.Tags['environment'] -match $Environment) -or 
    ($_.Tags['Environment'] -match $Environment) -or
    ($_.Name -match "-prod-" -and $Environment -eq 'prod')
}

# Group by VM size
$Grouped = $TargetVMs | Group-Object { $_.HardwareProfile.VmSize } | Sort-Object Count -Descending

$Results = @()
$TotalCurrentCost = 0
$TotalAfterRI = 0

foreach ($Group in $Grouped) {
    $Size = $Group.Name
    $Count = $Group.Count
    
    $MonthlyCost = $OnDemandPricing[$Size]
    if (-not $MonthlyCost) { continue }
    
    $GroupCost = $MonthlyCost * $Count
    $DiscountPct = $Discounts[$Term].Upfront
    $AfterRI = $GroupCost * (1 - $DiscountPct)
    $Savings = $GroupCost - $AfterRI
    
    $TotalCurrentCost += $GroupCost
    $TotalAfterRI += $AfterRI
    
    $Recommendation = if ($Count -ge 3) { 
        "BUY: Reserve $([math]::Floor($Count * 0.8)) RIs for $Size" 
    } elseif ($Count -ge 1) { 
        "SP: Use Savings Plan for flexibility across $Count VMs" 
    } else { 
        "MONITOR" 
    }
    
    $Results += [PSCustomObject]@{
        VMSize         = $Size
        Count          = $Count
        CurrentMonthly = "£$GroupCost"
        AfterRI_Monthly = "£$([math]::Round($AfterRI))"
        Savings_Monthly = "£$([math]::Round($Savings))"
        Savings_Pct    = "$([math]::Round($DiscountPct * 100))%"
        Recommendation = $Recommendation
    }
}

if ($Results) {
    $Results | Format-Table -AutoSize
    
    $AnnualSavings = ($TotalCurrentCost - $TotalAfterRI) * 12
    Write-Host "`n=== SUMMARY ===" -ForegroundColor Green
    Write-Host "Production VMs analysed: $($TargetVMs.Count)"
    Write-Host "Current monthly On-Demand: £$TotalCurrentCost"
    Write-Host "After RI ($Term): £$([math]::Round($TotalAfterRI))"
    Write-Host "Monthly savings: £$([math]::Round($TotalCurrentCost - $TotalAfterRI))"
    Write-Host "Annualised savings: £$AnnualSavings"
    
    # RI coverage guidance
    Write-Host "`n=== COVERAGE TARGETS ===" -ForegroundColor Cyan
    Write-Host "Production:   70-85% RI/SP coverage (buy RIs for stable, SP for variable)"
    Write-Host "Staging/UAT:  30-50% (SP only — workloads change frequently)"
    Write-Host "Dev/Test:     0% (use schedule shutdown, not commitments)"
}
else {
    Write-Host "`nNo production VMs found matching criteria." -ForegroundColor Yellow
}
