#Requires -Module Az.CostManagement, Az.Accounts
<#
.SYNOPSIS
    Exports Azure cost data for Power BI consumption with tag enrichment
    
.DESCRIPTION
    Production pattern for the full cost data pipeline:
    Azure Cost Management API → CSV → Power BI dataset.
    
    Exports daily cost data with resource metadata and tag allocation
    for showback/chargeback dashboards. Designed to run as a scheduled
    Azure Automation runbook feeding Power BI refresh.
    
    Output columns match the star schema in duvvur-skills/powerbi/dataset-schema/
    
.EXAMPLE
    .\Export-FinOpsCostData.ps1 -SubscriptionIds @("sub1","sub2") -DaysBack 30 -OutputPath ".\cost-export.csv"
    .\Export-FinOpsCostData.ps1 -SubscriptionIds @("sub1") -DaysBack 90 -Granularity Monthly -IncludeTags
    
.NOTES
    Author: Duvvur Sai Krishna
    Pipeline used for European insurance FinOps dashboards (3,000+ resources)
#>

param(
    [Parameter(Mandatory)]
    [string[]]$SubscriptionIds,
    
    [Parameter()]
    [int]$DaysBack = 30,
    
    [Parameter()]
    [string]$OutputPath = ".\cost-export-$(Get-Date -Format 'yyyy-MM-dd').csv",
    
    [Parameter()]
    [ValidateSet('Daily', 'Monthly')]
    [string]$Granularity = 'Daily',
    
    [Parameter()]
    [switch]$IncludeTags = $true,
    
    [Parameter()]
    [string]$Currency = 'GBP'
)

if (-not (Get-AzContext)) { Connect-AzAccount -Identity }

$EndDate = Get-Date
$StartDate = $EndDate.AddDays(-$DaysBack)
$AllRows = @()

foreach ($SubId in $SubscriptionIds) {
    Write-Host "Processing: $SubId" -ForegroundColor Cyan
    
    # Build tag grouping if requested
    $Grouping = @(
        @{ Name = 'ResourceGroup'; Type = 'Dimension' },
        @{ Name = 'ResourceType'; Type = 'Dimension' },
        @{ Name = 'MeterCategory'; Type = 'Dimension' },
        @{ Name = 'MeterSubCategory'; Type = 'Dimension' },
        @{ Name = 'PricingModel'; Type = 'Dimension' }
    )
    
    if ($IncludeTags) {
        $Grouping += @(
            @{ Name = 'tags'; Type = 'Dimension' }
        )
    }
    
    $QueryBody = @{
        type      = 'ActualCost'
        timeframe = 'Custom'
        timePeriod = @{
            from = $StartDate.ToString('yyyy-MM-dd')
            to   = $EndDate.ToString('yyyy-MM-dd')
        }
        dataset   = @{
            granularity  = $Granularity
            aggregation  = @{
                totalCost = @{
                    name     = 'Cost'
                    function = 'Sum'
                }
                totalUsage = @{
                    name     = 'UsageQuantity'
                    function = 'Sum'
                }
            }
            grouping = $Grouping
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        $Response = Invoke-AzRestMethod `
            -Path "/subscriptions/$SubId/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
            -Method POST `
            -Payload $QueryBody
        
        if ($Response.StatusCode -eq 200) {
            $Data = $Response.Content | ConvertFrom-Json
            $Columns = $Data.properties.columns | ForEach-Object { $_.name }
            
            foreach ($Row in $Data.properties.rows) {
                $CostIdx = [array]::IndexOf($Columns, 'Cost')
                $DateIdx = [array]::IndexOf($Columns, 'UsageDate')
                $RGIdx = [array]::IndexOf($Columns, 'ResourceGroup')
                $TypeIdx = [array]::IndexOf($Columns, 'ResourceType')
                $MeterIdx = [array]::IndexOf($Columns, 'MeterCategory')
                $SubMeterIdx = [array]::IndexOf($Columns, 'MeterSubCategory')
                $PriceIdx = [array]::IndexOf($Columns, 'PricingModel')
                $TagIdx = [array]::IndexOf($Columns, 'tags')
                $UsageIdx = [array]::IndexOf($Columns, 'UsageQuantity')
                $CurrencyIdx = [array]::IndexOf($Columns, 'Currency')
                
                $TagString = if ($TagIdx -ge 0 -and $Row[$TagIdx]) { $Row[$TagIdx] } else { '' }
                
                # Parse tags into individual columns for Power BI
                $CostCentre = ''; $Environment = ''; $Workload = ''; $Department = ''; $Owner = ''
                if ($TagString -and $TagString -ne '') {
                    $TagPairs = $TagString -split '`n'
                    foreach ($Pair in $TagPairs) {
                        if ($Pair -match 'cost-centre:(.+)') { $CostCentre = $Matches[1].Trim() }
                        if ($Pair -match 'environment:(.+)') { $Environment = $Matches[1].Trim() }
                        if ($Pair -match 'workload:(.+)') { $Workload = $Matches[1].Trim() }
                        if ($Pair -match 'department:(.+)') { $Department = $Matches[1].Trim() }
                        if ($Pair -match 'owner:(.+)') { $Owner = $Matches[1].Trim() }
                    }
                }
                
                $DateVal = if ($DateIdx -ge 0) { 
                    $raw = $Row[$DateIdx]
                    if ($raw -match '^\d{8}$') { "$($raw.Substring(0,4))-$($raw.Substring(4,2))-$($raw.Substring(6,2))" } else { $raw }
                } else { '' }
                
                $AllRows += [PSCustomObject]@{
                    Date             = $DateVal
                    SubscriptionId   = $SubId
                    ResourceGroup    = if ($RGIdx -ge 0) { $Row[$RGIdx] } else { '' }
                    ResourceType     = if ($TypeIdx -ge 0) { $Row[$TypeIdx] } else { '' }
                    MeterCategory    = if ($MeterIdx -ge 0) { $Row[$MeterIdx] } else { '' }
                    MeterSubCategory = if ($SubMeterIdx -ge 0) { $Row[$SubMeterIdx] } else { '' }
                    PricingModel     = if ($PriceIdx -ge 0) { $Row[$PriceIdx] } else { '' }
                    Cost             = [math]::Round($Row[$CostIdx], 2)
                    UsageQuantity    = [math]::Round($Row[$UsageIdx], 4)
                    Currency         = if ($CurrencyIdx -ge 0) { $Row[$CurrencyIdx] } else { $Currency }
                    CostCentre       = $CostCentre
                    Environment      = $Environment
                    Workload         = $Workload
                    Department       = $Department
                    Owner            = $Owner
                    IsAllocated      = [bool]$CostCentre
                }
            }
            Write-Host "  ✓ $($Data.properties.rows.Count) rows" -ForegroundColor Green
        }
        else {
            Write-Warning "  ✗ $($Response.StatusCode): $($Response.Content.Substring(0, [math]::Min(200, $Response.Content.Length)))"
        }
    }
    catch {
        Write-Error "  ✗ Error: $_"
    }
}

# Export
$AllRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$TotalCost = ($AllRows | Measure-Object -Property Cost -Sum).Sum
$Allocated = ($AllRows | Where-Object { $_.IsAllocated }).Count
$Total = $AllRows.Count

Write-Host "`n=== EXPORT COMPLETE ===" -ForegroundColor Green
Write-Host "Rows:          $Total"
Write-Host "Total cost:    $([math]::Round($TotalCost, 2)) $Currency"
Write-Host "Allocated:     $Allocated / $Total ($([math]::Round($Allocated/$Total*100,1))%)"
Write-Host "File:          $OutputPath"
Write-Host ""
Write-Host "Next: Import into Power BI using the star schema from duvvur-skills/powerbi/dataset-schema/"
