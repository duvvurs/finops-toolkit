#Requires -Module Az.Resources, Az.Accounts
<#
.SYNOPSIS
    Audits and enforces tagging compliance for FinOps cost allocation
    
.DESCRIPTION
    Enterprise tagging governance script. Measures compliance against a
    required tag set, reports per-subscription, and can enforce tags
    by inheriting from Resource Group level.
    
    Rollout phases:
    1. Audit — report compliance % (no changes)
    2. Enforce — auto-tag from Resource Group where missing
    3. Report — export CSV for stakeholder review
    
.EXAMPLE
    .\Invoke-FinOpsTagCompliance.ps1 -SubscriptionIds @("sub1") -Mode Audit
    
.NOTES
    Author: Duvvur Sai Krishna
#>

param(
    [Parameter(Mandatory)]
    [string[]]$SubscriptionIds,
    
    [Parameter()]
    [ValidateSet('Audit', 'Enforce', 'Report')]
    [string]$Mode = 'Audit',
    
    [Parameter()]
    [hashtable]$RequiredTags = @{
        'cost-centre'         = ''
        'environment'         = ''
        'workload'            = ''
        'owner'               = ''
        'department'          = ''
        'data-classification' = ''
    }
)

$Results = @()

foreach ($SubId in $SubscriptionIds) {
    Write-Host "`n--- Subscription: $SubId ---" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $SubId | Out-Null
    
    $Resources = Get-AzResource
    $Total = $Resources.Count
    $Compliant = 0
    $TagStats = @{}
    
    foreach ($Tag in $RequiredTags.Keys) {
        $TagStats[$Tag] = @{ Present = 0; Missing = 0 }
    }
    
    foreach ($Resource in $Resources) {
        $AllPresent = $true
        foreach ($Tag in $RequiredTags.Keys) {
            if ($Resource.Tags -and $Resource.Tags.ContainsKey($Tag) -and $Resource.Tags[$Tag]) {
                $TagStats[$Tag].Present++
            } else {
                $TagStats[$Tag].Missing++
                $AllPresent = $false
                
                if ($Mode -eq 'Enforce') {
                    $RGTags = (Get-AzResourceGroup -Name $Resource.ResourceGroupName -ErrorAction SilentlyContinue).Tags
                    if ($RGTags -and $RGTags.ContainsKey($Tag)) {
                        $TagsToAdd = @{ $Tag = $RGTags[$Tag] }
                        Update-AzTag -ResourceId $Resource.ResourceId -Tag $TagsToAdd -Operation Merge -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        if ($AllPresent) { $Compliant++ }
    }
    
    $CompliancePct = [math]::Round(($Compliant / $Total) * 100, 1)
    
    $Results += [PSCustomObject]@{
        Subscription  = $SubId
        Total         = $Total
        Compliant     = $Compliant
        CompliancePct = $CompliancePct
        PctCostCentre = [math]::Round(($TagStats['cost-centre'].Present / $Total) * 100, 1)
        PctEnvironment = [math]::Round(($TagStats['environment'].Present / $Total) * 100, 1)
        PctWorkload   = [math]::Round(($TagStats['workload'].Present / $Total) * 100, 1)
        PctOwner      = [math]::Round(($TagStats['owner'].Present / $Total) * 100, 1)
    }
    
    $Colour = if ($CompliancePct -ge 90) { 'Green' } elseif ($CompliancePct -ge 70) { 'Yellow' } else { 'Red' }
    Write-Host "  Compliance: $CompliancePct% ($Compliant/$Total)" -ForegroundColor $Colour
}

if ($Mode -eq 'Report') {
    $Results | Format-Table -AutoSize
    $Results | Export-Csv -Path "tag-compliance-$(Get-Date -Format 'yyyy-MM-dd').csv" -NoTypeInformation
}

$AvgCompliance = [math]::Round(($Results | Measure-Object -Property CompliancePct -Average).Average, 1)
Write-Host "`n=== OVERALL: $AvgCompliance% avg compliance across $($Results.Count) subscriptions ===" -ForegroundColor $(if ($AvgCompliance -ge 90) { 'Green' } else { 'Yellow' })
