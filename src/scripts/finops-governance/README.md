# FinOps Governance Scripts

> Production-grade Azure governance automation for FinOps practitioners. Derived from 12+ years of Azure infrastructure and cost optimization work across European enterprises.

## Scripts

| Script | Purpose | Prerequisites |
|--------|---------|---------------|
| [`Invoke-FinOpsTagCompliance.ps1`](./Invoke-FinOpsTagCompliance.ps1) | Audit and enforce tagging compliance across subscriptions | Az.Resources, Az.Accounts |
| [`New-FinOpsBudgetWithEscalation.ps1`](./New-FinOpsBudgetWithEscalation.ps1) | Create budget alerts with tiered escalation (50/80/100%) | Az.Billing, Az.Accounts |
| [`Export-FinOpsCostData.ps1`](./Export-FinOpsCostData.ps1) | Export Azure cost data for Power BI consumption | Az.CostManagement, Az.Accounts |
| [`Invoke-FinOpsRightsizingAssessment.ps1`](./Invoke-FinOpsRightsizingAssessment.ps1) | Identify over-provisioned VMs and recommend SKUs | Az.Compute, Az.Monitor, Az.Accounts |
| [`Get-FinOpsRIOpportunity.ps1`](./Get-FinOpsRIOpportunity.ps1) | Analyze On-Demand VM usage for RI/SP coverage opportunities | Az.Consumption, Az.Compute, Az.Accounts |

## Quick Start

```powershell
# Install required modules
Install-Module Az.Resources, Az.CostManagement, Az.Compute, Az.Monitor -Force

# Connect
Connect-AzAccount

# Run tag compliance audit
./Invoke-FinOpsTagCompliance.ps1 -SubscriptionIds @("sub1","sub2") -Mode Audit

# Create budget with escalation
./New-FinOpsBudgetWithEscalation.ps1 -SubscriptionId "sub1" -BudgetName "Monthly-FinOps" -Amount 50000 -AlertEmails @("finops@company.com")

# Export cost data for Power BI
./Export-FinOpsCostData.ps1 -SubscriptionIds @("sub1","sub2") -DaysBack 30 -OutputPath ".\cost-export.csv"

# Assess rightsizing opportunities
./Invoke-FinOpsRightsizingAssessment.ps1 -SubscriptionId "sub1" -CpuThreshold 15 -DaysBack 14

# Find RI coverage opportunities
./Get-FinOpsRIOpportunity.ps1 -SubscriptionId "sub1" -Environment "prod"
```

## Context

These patterns were developed and refined across multiple international engagements:

- **European Insurance** — Multi-subscription cost governance, showback/chargeback, 3,000+ resources
- **UK Water Utility** — Architecture redesign delivering £52K/month (£624K annualised) savings
- **Microsoft India** — Azure commercial constructs (EA/MCA/CSP), customer cloud adoption

All client-specific data has been sanitized. Scripts use generic parameters.
