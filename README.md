![test-policies](https://github.com/fawohlsc/azure-policy-testing/workflows/test-policies/badge.svg)

# Testing Azure Policy

## Introduction
This repository outlines an automated testing approach for Azure Policies. The approach is fundamentally based on behavior-driven development (BDD) to improve communication between developers, security experts and compliance officers. The PowerShell testing framework Pester, Azure PowerShell and GitHub Actions are used in conjunction to automate the tests and run them as part of a DevOps pipeline. After the problem statement, the solution is described in more detail including how to set it up in your Azure environment.

## Problem Statement
Let's start simple: Why should you test Azure Policy in the first place? It's just configuration not code. This is a fair statement, but any configuration changes on Azure Policies can be highly impactful and when done wrong even lead to production outages. Just see this example for an Azure Policy, which is quite common for enterprise customers adopting Azure (See: [Hub-spoke network topology in Azure](https://docs.microsoft.com/en-us/azure/architecture/reference-architectures/hybrid-networking/hub-spoke)). In a nutshell, whenever a route table is created, a user-defined route (UDR) should be added to route all internet traffic to a virtual appliance hosted centrally in the hub virtual network for outbound traffic inspection:

```json
{
    "name": "[variables('policyName')]",
    "type": "Microsoft.Authorization/policyDefinitions",
    "apiVersion": "2020-03-01",
    "properties": {
        "policyType": "Custom",
        "mode": "All",
        "displayName": "[variables('policyName')]",
        "description": "[variables('policyDescription')]",
        "metadata": {
            "category": "[variables('policyCategory')]"
        },
        "parameters": {
            "routeTableSettings": {
                "type": "Object",
                "metadata": {
                    "displayName": "Route Table Settings",
                    "description": "Location-specific settings for route tables."
                }
            }
        },
        "policyRule": {
            "if": {
                "allOf": [
                    {
                        "field": "type",
                        "equals": "Microsoft.Network/routeTables"
                    },
                    {
                        "count": {
                            "field": "Microsoft.Network/routeTables/routes[*]",
                            "where": {
                                "field": "Microsoft.Network/routeTables/routes[*].addressPrefix",
                                "equals": "0.0.0.0/0"
                            }
                        },
                        "equals": 0
                    }
                ]
            },
            "then": {
                "effect": "modify",
                "details": {
                    "roleDefinitionIds": [
                        "[variables('policyRoleDefinitionId')]"
                    ],
                    "conflictEffect": "audit",
                    "operations": [
                        {
                            "operation": "add",
                            "field": "Microsoft.Network/routeTables/routes[*]",
                            "value": {
                                "name": "default",
                                "properties": {
                                    "addressPrefix": "0.0.0.0/0",
                                    "nextHopType": "VirtualAppliance",
                                    "nextHopIpAddress": "[[parameters('routeTableSettings')[field('location')].virtualApplianceIpAddress]"
                                }
                            }
                        }
                    ]
                }
            }
        }
    }
}
```
Now just imagine, we configured the wrong IP addresses for our virtual appliance or we forgot to add this route at all. Depending on the scope of the policy assignment, a lot of applications might stop working. So we should test it, since any change might have an high impact on production environments.

## Solution

### Test Pyramid
So how can we test Azure Policy? Which kind of tests should we perform? Martin Fowler listed these test categories in his definition of a [test pyramid](https://martinfowler.com/bliki/TestPyramid.html):

![Martin Fowler's definition of a test pyramid](./docs/test-pyramid.png)

**UI tests** typically are recording the interaction of the user with the user interface. When it comes to testing Azure Policy, a lot of people heavily rely on UI Tests using the Azure Portal. Basically, clicking through the Azure Portal and document each step. While this seems fine to get started with testing policies, its also very slow since a human being has to click through the portal and document each step. Since multiple policies can be assigned to the same scope or inherited from parent scopes (Management Group, Subscription and Resource Group), introducing a new policy can lead to regression bugs when overlapping with other existing policies (See: [Layering policy definitions
](https://docs.microsoft.com/en-us/azure/governance/policy/concepts/effects#layering-policy-definitions)). Just think of an example with two policies overlapping and both of them allowing different Azure regions for deployment - no deployment at all will be possible. Basically, this requires a lot of additional regression testing and further slows down the testing process. So, what about these handy tools for UI automation testing? Both automated and manual UI tests will be hard to maintain, since Azure is rapidly evolving and so is the Azure Portal. Additionally, browser caching issues might lead to false positives during UI testing. To cut a long story short, it is not possible to use manual or automated UI tests to validate Azure Policy in an effective and scalable manner, they are time consuming to run and hard to maintain.

**Service tests** or **API tests** are actual code targeting the API layer. In the context of Azure Policy, you could actually call the [Azure REST API](https://docs.microsoft.com/en-us/rest/api/azure/) to perform tests, which is a much more stable and versioned contract to test against than the UI. Also, regression testing can be done way easier by just running all the test scripts either manually triggered or even better by performing [continuous integration](https://martinfowler.com/articles/continuousIntegration.html) within your DevOps pipeline of choice, i.e. [GitHub Actions](https://github.com/features/actions). Finally, since the tests are written as code, parallelization techniques can be applied to speed up the tests. Taking into consideration that performing compliance scans and remediation with Azure Policy can take a few minutes per test, parallelization helps to scale the test suite to potentially hundreds of tests. Going forward, we will prefer the term *API tests* instead of *service tests* since much more applicable when testing policies.

**Unit tests** are the fastest and cheapest way to gain feedback to verify that a single unit of code, e.g. a class or a method, are actually working as expected. Typically, unit tests are focused on testing business logic. Unfortunately, they also require to have the code under test available. This does not apply to Azure Policy, since the policy engine itself is not available to the public. If this ever changes, most of your test suite should become unit tests as indicated by the different sizes for the surface areas in the test pyramid. Additionally, service tests might be used to validate policy remediation, which cannot be done with unit tests. Finally, if UI tests are used at all, they might be just limited to smoke testing.

In summary, **UI tests** are not suitable for testing Azure Policy at scale and **Unit tests** are not doable without the policy engine being available to the public. Hence, we will focus on testing Azure Policy with **API tests** going forward.

### API Tests
For our API Tests, we will use **Azure PowerShell** to call the Azure REST API. Hence the question, why are we not calling the API directly? 

First, Azure PowerShell handles a lot of low-level details which you would be exposed to when directly calling the API. For instance, for long-running operations, the HTTP status code 202 (Accepted) and an URL for the status update to determine when the operation is completed is returned. This basically means that you have to perform [busy waiting](https://en.wikipedia.org/wiki/Busy_waiting) and periodically call the URL for the status update to wait for the operations to complete. Later is important for policy remediation and compliance scans, which can take a few minutes to complete. All this is already handled for you in Azure PowerShell (See: [LongRunningOperationHelper.cs](https://github.com/Azure/azure-powershell/blob/1bcbe7b1f7a3323ac98f7754ba03eeb6b45e79f2/src/Resources/ResourceManager/Components/LongRunningOperationHelper.cs#L139)). Just see this sample code written in Azure PowerShell, which is easy to understand even without a lot of explanations:

```powershell
# Create route table.
$routeTable = New-AzRouteTable `
    -Name "route-table" `
    -ResourceGroupName $ResourceGroup.ResourceGroupName `
    -Location $ResourceGroup.Location

# Verify that route 0.0.0.0/0 was added by policy.
$routeTable
| Test-RouteNextHopVirtualAppliance
| Should -BeTrue
```

Second, Azure PowerShell also allows you to fallback and conveniently directly call the Azure REST API when needed:

```powershell
$httpResponse = Invoke-AzRestMethod `
    -ResourceGroupName $RouteTable.ResourceGroupName `
    -ResourceProviderName "Microsoft.Network" `
    -ResourceType @("routeTables", "routes") `
    -Name @($RouteTable.Name, $Route.Name) `
    -ApiVersion "2020-05-01" `
    -Method "DELETE"

# Handling the HTTP status codes returned by the DELETE request for route.
# See also: https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/delete
# Accepted.
if ($httpResponse.StatusCode -eq 200) {
    # All good, do nothing.
}
# Accepted and the operation will complete asynchronously.
elseif ($httpResponse.StatusCode -eq 202) {
    # Invoke-AzRestMethod currently does not support awaiting asynchronous operations.
    # See also: https://github.com/Azure/azure-powershell/issues/13293
    $asyncOperation = $httpResponse | Wait-AsyncOperation
    if ($asyncOperation.Status -ne "Succeeded") {
        throw "Asynchronous operation failed with message: '$($asyncOperation)'"
    }
}
# Route was deleted or not found.
elseif ($httpResponse.StatusCode -eq 204) {
    # All good, do nothing
}
# Error response describing why the operation failed.
else {
    throw "Operation failed with message: '$($httpResponse.Content)'"
}
```

Additionally, you can view any underlying HTTP request initiated by Azure PowerShell and the corresponding HTTP response even when using the high-level methods using the ```-Debug``` flag:

```powershell
Get-AzResourceGroup -Debug
```
![Detailed output of Azure PowerShell when using -Debug flag](./docs/azure-powershell-debug.png)

Third, Azure Policy is well supported and documented in Azure PowerShell. Just see this more complex example to trigger a long-running policy remediation including an upfront compliance scan for a policy with [Modify](https://docs.microsoft.com/en-us/azure/governance/policy/concepts/effects#modify) effect:

```powershell
# Trigger and wait for remediation.
$job = Start-AzPolicyRemediation `
    -Name "$($Resource.Name)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())" `
    -Scope $Resource.Id `
    -PolicyAssignmentId $policyAssignmentId `
    -ResourceDiscoveryMode ReEvaluateCompliance `
    -AsJob
$remediation = $job | Wait-Job | Receive-Job

# Check remediation provisioning state and deployment when required.
$succeeded = $remediation.ProvisioningState -eq "Succeeded"
```

When using Azure PowerShell or PowerShell in general, you can also make use of its powerful test framework [Pester](https://pester.dev/docs/quick-start). Pester is based on [Behavior-driven Development](https://en.wikipedia.org/wiki/Behavior-driven_development) (BDD), a software development approach that has evolved from [Test-driven Development](https://en.wikipedia.org/wiki/Test-driven_development) (TDD). It differs by being written in a shared [Domain-specific Language](https://en.wikipedia.org/wiki/Domain-specific_language) (DSL), which improves communication between tech and non-tech teams and stakeholders, i.e. developers creating Azure Policies and compliance officers and security experts defining their requirements. In both development approaches, tests are written ahead of the code, but in BDD, tests are more user-focused and based on the system’s behavior (See: [Powershell BDD with Pester](https://www.netscylla.com/blog/2019/04/28/Powershell-BDD-with-Pester.html)). In the context of Azure Policy, a test written in Pester might look like this:

```powershell
Context "When route table is created or updated" -Tag "modify-routetable-nexthopvirtualappliance-routetable-create-update" {
    It "Should add missing route 0.0.0.0/0 pointing to the virtual appliance" -Tag "modify-routetable-nexthopvirtualappliance-routetable-create-update-10" {
        AzTest -ResourceGroup {
            param($ResourceGroup)
            
            $routeTable = New-AzRouteTable `
                -Name "route-table" `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location
        
            # Verify that route 0.0.0.0/0 was added by policy.
            $routeTable
            | Test-RouteNextHopVirtualAppliance
            | Should -BeTrue
        }
    }
}
```

Also, the test results are very easy to grasp, by just looking at the detailed output of [Invoke-Pester](https://github.com/pester/Pester#simple-and-advanced-interface):
![Test results generated by Pester](./docs/pester-test-results.png)

Finally, Pester tests can also run during [continuous integration](https://martinfowler.com/articles/continuousIntegration.html) as part of your DevOps pipeline. Following an example using [GitHub Actions](https://github.com/features/actions) (See: [test-policies.yml](./.github/workflows/test-policies.yml)):

```yaml
- name: Test Azure Policies
  shell: pwsh
  run: |
     Invoke-Pester -Output Detailed -CI
```

As you can see, we can combine Pester and Azure PowerShell to conveniently test Azure Policy. But how does this look in more detail? How to test the different [Azure Policy effects](https://docs.microsoft.com/en-us/azure/governance/policy/concepts/effects)? Let's put them into buckets to ease the conversation:
- **Synchronously** evaluated
- **Asynchronously** evaluated
- **Asynchronously** evaluated with **remediation task** support

Policy effects, which are **synchronously** evaluated are *Append*, *Deny* and *Modify* (See: [Deny-Route-NextHopVirtualAppliance](./policies/Deny-Route-NextHopVirtualAppliance.json)). Basically, the policies already take effect during the PATCH/PUT request. Testing them with Azure PowerShell is quiet straightforward and basically just performing a PATCH/PUT request like creating a route (See: [Deny-Route-NextHopVirtualAppliance.Tests.ps1](./tests/Deny-Route-NextHopVirtualAppliance.Tests.ps1)):

```powershell
Context "When route is created or updated" -Tag "deny-route-nexthopvirtualappliance-route-create-update" {
It "Should deny incompliant route 0.0.0.0/0 with next hop type 'None'" -Tag "deny-route-nexthopvirtualappliance-route-create-update-10" {
        AzTest -ResourceGroup {
            param($ResourceGroup)
            
            $routeTable = New-AzRouteTable `
                -Name "route-table" `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location

            # Should be disallowed by policy, so exception should be thrown.
            {
                # Directly calling REST API with PUT routes, since New-AzRouteConfig/Set-AzRouteTable will issue PUT routeTables.
                $routeTable | Invoke-RoutePut `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "None" # Incompliant.
            } | Should -Throw "*RequestDisallowedByPolicy*Deny-Route-NextHopVirtualAppliance*"
        }
    }
}
```

For reusability reasons, the utility methods like ```AzTest``` were moved into dedicated PowerShell Modules (See: [Test.Utils.psm1](./utils/Test.Utils.psm1)):

```powershell
function AzTest {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [ScriptBlock] $Test,
        [Parameter()]
        [Switch] $ResourceGroup
    )

    # Retries the test on transient errors.
    AzRetry {
        # When a dedicated resource group should be created for the test.
        if ($ResourceGroup) {
            try {
                $resourceGroup = New-ResourceGroupTest
                Invoke-Command -ScriptBlock $Test -ArgumentList $resourceGroup
            }
            finally {
                # Stops on failures during clean-up. 
                AzCleanUp {
                    Remove-AzResourceGroup -Name $ResourceGroup.ResourceGroupName -Force -AsJob
                }
            }
        }
        else {
            Invoke-Command -ScriptBlock $Test
        }
    }
}
```

**Asynchronously** evaluated policy effects are *Audit* and *AuditIfNotExists*. The PATCH/PUT request just triggers a compliance scan, but the evaluation happens asynchronously in the background, e.g. [Audit-Route-NextHopVirtualAppliance](./policies/Audit-Route-NextHopVirtualAppliance.json). As it turns out, we can manually trigger a compliance scan and wait for its completion by using Azure PowerShell (See: [Audit-Route-NextHopVirtualAppliance.Tests.ps1](./tests/Audit-Route-NextHopVirtualAppliance.Tests.ps1) and [Policy.Utils.psm1](./utils/Policy.Utils.psm1)):

```powershell
Context "When auditing route tables" {
    It "Should mark route table as compliant with route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-compliant" {
        AzTest -ResourceGroup {
            param($ResourceGroup)

            # Create compliant route table.
            $route = New-AzRouteConfig `
                -Name "default" `
                -AddressPrefix "0.0.0.0/0" `
                -NextHopType "VirtualAppliance" `
                -NextHopIpAddress (Get-VirtualApplianceIpAddress -Location $ResourceGroup.Location)
                        
            $routeTable = New-AzRouteTable `
                -Name "route-table" `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location `
                -Route $Route

            # Trigger compliance scan for resource group and wait for completion.
            $ResourceGroup | Complete-PolicyComplianceScan 

            # Verify that route table is compliant.
            $routeTable 
            | Get-PolicyComplianceState -PolicyDefinitionName "Audit-Route-NextHopVirtualAppliance"
            | Should -BeTrue
        }
    }
}

function Complete-PolicyComplianceScan {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroup]$ResourceGroup,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )

    # Policy compliance scan might fail, hence retrying to avoid flaky tests.
    $retries = 0
    do {
        $job = Start-AzPolicyComplianceScan -ResourceGroupName $ResourceGroup.ResourceGroupName -PassThru -AsJob 
        $succeeded = $job | Wait-Job | Receive-Job
        
        if ($succeeded) {
            break
        }
        # Failure: Retry policy compliance scan when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            Write-Host "Policy compliance scan for resource group '$($ResourceGroup.ResourceId)' failed. Retrying..."
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Policy compliance scan is still failing after maximum retries.
        else {
            throw "Policy compliance scan for resource group '$($ResourceGroup.ResourceId)' failed even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.
}

function Get-PolicyComplianceState {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$WaitSeconds = 60,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 30
    )

    # Policy compliance scan might be completed, but policy compliance state might still be null due to race conditions.
    # Hence waiting a few seconds and retrying to get the policy compliance state to avoid flaky tests.
    $retries = 0
    do {
        $isCompliant = (Get-AzPolicyState `
                -PolicyDefinitionName $PolicyDefinitionName `
                -Filter "ResourceId eq '$($Resource.Id)'" `
        ).IsCompliant
        
        # Success: Policy compliance state is not null.
        if ($null -ne $isCompliant) {
            break
        }
        # Failure: Policy compliance state is null, so wait a few seconds and retry when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            Write-Host "Policy '$($PolicyDefinitionName)' completed compliance scan for resource '$($Resource.Id)', but policy compliance state is null. Retrying..."
            Start-Sleep -Seconds $WaitSeconds
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Policy compliance state still null after maximum retries.
        else {
            throw "Policy '$($PolicyDefinitionName)' completed compliance scan for resource '$($Resource.Id)', but policy compliance state is null even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.

    return $isCompliant
}
```

Last but not least, the **asynchronously** evaluated policy effects with **remediation task** support are *DeployIfNotExists* and *Modify*. Just like the asynchronously evaluated policies, the compliance scan happens in the background. Additionally, non-compliant resources can be remediated with a remediation task. When testing these kind of policy effects, the easiest way is to just start a remediation task including an upfront compliance scan (See: [Modify-RouteTable-NextHopVirtualAppliance.Tests.ps1](./tests/Modify-RouteTable-NextHopVirtualAppliance.Tests.ps1) and [Policy.Utils.psm1](./utils/Policy.Utils.psm1)):

```powershell
Context "When route is deleted" -Tag "modify-routetable-nexthopvirtualappliance-route-delete" {
    It "Should remediate missing route 0.0.0.0/0 pointing to the virtual appliance" -Tag "modify-routetable-nexthopvirtualappliance-route-delete-10" {
        AzTest -ResourceGroup {
            param($ResourceGroup)

            $routeTable = New-AzRouteTable `
                -Name "route-table" `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location
            
            # Get route 0.0.0.0/0 pointing to the virtual appliance, which was added by policy.
            $route = Get-RouteNextHopVirtualAppliance -RouteTable $routeTable
            
            # Remove-AzRouteConfig/Set-AzRouteTable will issue a PUT request for routeTables and hence policy might kick in.
            # In order to delete the route without policy interfering, directly call the REST API by issuing a DELETE request for route.
            $routeTable | Invoke-RouteDelete -Route $route
        
            # Remediate route table by policy and wait for completion.
            $routeTable | Complete-PolicyRemediation -PolicyDefinitionName "Modify-RouteTable-NextHopVirtualAppliance" -CheckDeployment
        
            # Verify that route 0.0.0.0/0 was added by policy remediation.
            Get-AzRouteTable -ResourceGroupName $routeTable.ResourceGroupName -Name $routeTable.Name
            | Test-RouteNextHopVirtualAppliance
            | Should -BeTrue
        }
    }
}

function Complete-PolicyRemediation {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PolicyDefinitionName,
        [Parameter()]
        [switch]$CheckDeployment,
        [Parameter()]
        [ValidateRange(1, [ushort]::MaxValue)]
        [ushort]$MaxRetries = 3
    )
    
    # Determine policy assignment id.
    $scope = "/subscriptions/$((Get-AzContext).Subscription.Id)"
    $policyAssignmentId = (Get-AzPolicyAssignment -Scope $scope
        | Select-Object -Property PolicyAssignmentId -ExpandProperty Properties 
        | Where-Object { $_.PolicyDefinitionId.EndsWith($PolicyDefinitionName) } 
        | Select-Object -Property PolicyAssignmentId -First 1
    ).PolicyAssignmentId
    
    if ($null -eq $policyAssignmentId) {
        throw "Policy '$($PolicyDefinitionName)' is not assigned to scope '$($scope)'."
    }

    # Remediation might be started before all previous changes on the resource in scope are completed.
    # This race condition could lead to a successful remediation without any deployment being triggered.
    # When a deployment is expected, it might be required to retry remediation to avoid flaky tests.
    $retries = 0
    do {
        # Trigger and wait for remediation.
        $job = Start-AzPolicyRemediation `
            -Name "$($Resource.Name)-$([DateTimeOffset]::Now.ToUnixTimeSeconds())" `
            -Scope $Resource.Id `
            -PolicyAssignmentId $policyAssignmentId `
            -ResourceDiscoveryMode ReEvaluateCompliance `
            -AsJob
        $remediation = $job | Wait-Job | Receive-Job
        
        # Check remediation provisioning state and deployment when required.
        $succeeded = $remediation.ProvisioningState -eq "Succeeded"
        if ($succeeded) {
            if ($CheckDeployment) {
                $deployed = $remediation.DeploymentSummary.TotalDeployments -gt 0
                
                # Success: Deployment was triggered.
                if ($deployed) {
                    break 
                }
                # Failure: No deployment was triggered, so retry when still below maximum retries.
                elseif ($retries -le $MaxRetries) {
                    Write-Host "Policy '$($PolicyDefinitionName)' succeeded to remediated resource '$($Resource.Id)', but no deployment was triggered. Retrying..."
                    $retries++
                    continue # Not required, just defensive programming.
                }
                # Failure: No deployment was triggered even after maximum retries.
                else {
                    throw "Policy '$($PolicyDefinitionName)' succeeded to remediated resource '$($Resource.Id)', but no deployment was triggered even after $($MaxRetries) retries."
                }
            }
            # Success: No deployment need to checked, hence no retry required.
            else {
                break
            }
        }
        # Failure: Remediation failed, so retry when still below maximum retries.
        elseif ($retries -le $MaxRetries) {
            Write-Host "Policy '$($PolicyDefinitionName)' failed to remediate resource '$($Resource.Id)'. Retrying..."
            $retries++
            continue # Not required, just defensive programming.
        }
        # Failure: Remediation failed even after maximum retries.
        else {
            throw "Policy '$($PolicyDefinitionName)' failed to remediate resource '$($Resource.Id)' even after $($MaxRetries) retries."
        }
    } while ($retries -le $MaxRetries) # Prevent endless loop, just defensive programming.
}
```

>Please note, that *Modify* can be evaluated both **synchronously** and **asynchronously**. 

As you can see, the combination of Pester, Azure PowerShell and GitHub Actions is quiet powerful and convenient for testing Azure Policy. In the next chapter, we will describe how to setup this repository with your GitHub account using your Azure environment, so you can further explore it.

## Setup
### Folder Structure
Before going into the steps to setup this repository with your GitHub account using your Azure environment, it is important to understand how the folders in this repository are structured (generated by using the [tree](http://mama.indstate.edu/users/ice/tree/) command):

```bash
.
├── .azure-pipelines
├── .github
├── docs
├── policies
├── tests
└── utils
```

- **.azure-pipelines**: Leverage the [Azure YAML pipeline](https://docs.microsoft.com/en-us/azure/devops/pipelines/yaml-schema?view=azure-devops&tabs=schema%2Cparameter-schema) when you want to deploy and test policies in your subscription using Azure DevOps.
- **.github**: Leverage the [GitHub Actions workflow](https://github.com/features/actions) when you want to deploy and test policies in your subscription using GitHub Actions.
- **docs**: The Markdown files and images used for documentation purposes are placed in this folder, except the **README.md** at the root, which serves as the entry point.
- **policies**: All the policy definitions and assignments are placed here. Each policy is wrapped in an [ARM template](https://docs.microsoft.com/en-us/azure/azure-resource-manager/templates/overview) to ease deployment, e.g.:
```powershell
Get-ChildItem -Path "./policies" | ForEach-Object {
    New-AzDeployment -Location "northeurope" -TemplateFile $_.FullName
}
```
- **tests**: This is were all the magic happens. Each policy is tested by a corresponding PowerShell script.
- **utils**: For reusability reasons, the utility methods are moved into dedicated PowerShell modules. 

### Step Guide
1. **Prerequisite:** You should have installed Azure CLI on your local machine to run the command or use the Azure CloudShell in the Azure portal. To install Azure CLI, follow [Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest). To use Azure CloudShell, follow [Quickstart for Bash in Azure Cloud Shell](https://docs.microsoft.com/en-us/azure/cloud-shell/quickstart).
2. **Prerequisite:** Verify that [jq](https://stedolan.github.io/jq/) is installed on your system by running ```jq --version```. It should already come pre-installed in Azure CloudShell. If you run the Azure CLI commands locally you might have to install it, e.g. Ubuntu:

    ```bash
    sudo apt-get install jq
    ```

3. Fork this repository (See: [Fork a repo](https://docs.github.com/en/free-pro-team@latest/github/getting-started-with-github/fork-a-repo))

![Create a repository fork in GitHub](./docs/github-fork.png)

4. Create a [GitHub Secret](https://www.edwardthomson.com/blog/github_actions_11_secrets.html) named ```AZURE_SUBSCRIPTION_ID``` with the value being your Azure Subscription ID. You can retrieve the ID using the Azure CLI:

    ```bash
    az account show | jq -r '.id'
    ```
5. Create a [GitHub Secret](https://www.edwardthomson.com/blog/github_actions_11_secrets.html) named ```AZURE_CREDENTIALS``` with the value being the JSON object outputted by this Azure CLI command:
    
    ```bash
    az ad sp create-for-rbac --name "azure-policy-testing" --role "Owner"  \
    --scopes /subscriptions/{YOUR AZURE SUBSCRIPTION ID} \
    --sdk-auth
    ```
    
3. Change the ```README.md``` to represent your build status:
    
    ```markdown
    ![test-policies](https://github.com/{YOUR GITHUB HANDLE}/azure-policy-testing/workflows/test-policies/badge.svg)
    ```
    
4. Manually run the ```test-policies``` GitHub workflow and wait for it to complete successfully: 

![Run the GitHub workflow](./docs/github-run-workflow.png)

5. Alternatively, you can perform a code change on either the GitHub workflow, policies, tests, or utils in the main branch to trigger the workflow by continuous integration.

6. Anyways, the build status should be reflected in your repository as well:

![GitHub build status is passing](./docs/github-build-status.png)

7. **Congrats, you are done!** Your feedback is very much appreciated, either by starring this repository, opening a pull request or by raising an issues. Many thanks upfront!


## FAQ
### What should we consider when designing tests for policies?
There are many different 1st and 3rd party tools to provision resources in Azure e.g. ARM templates, Azure PowerShell, and Terraform. Under the hood, all of them are calling the Azure REST API. Hence, it makes sense to carefully study the [Azure REST API reference](https://docs.microsoft.com/en-us/rest/api/azure/) and [Azure REST API guidelines](https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md) when designing tests for policies. Especially consider:
- Structure your test cases around Azure REST API calls consider i.e., PUT, PATCH and DELETE requests. Basically, any request which can can lead to your resources being incompliant.
- When the [resource provider](https://docs.microsoft.com/en-us/azure/azure-resource-manager/management/resource-providers-and-types) does not support PATCH requests, you do not need separate test cases for creating and updating resources since they both result in the same PUT request.
- Also consider that some properties are optional, so they might not be sent as part of the PUT requests. You can leverage the [Azure REST API reference](https://docs.microsoft.com/en-us/rest/api/azure/) to check if a property is optional or required. In case the policy alias you are using is referring to an optional property, you should create a dedicated test case to validate the behavior of your policy.
- Some child resources e.g., [route](https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/createorupdate), can be created standalone or wrapped as inline property and created as part of their their parent resource e.g., [route table](https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routetables/createorupdate#request-body). Keep that in mind when designing and testing polices e.g., policy [Deny-Route-NextHopVirtualAppliance.json](./policies/Deny-Route-NextHopVirtualAppliance.json) and the corresponding tests [Deny-Route-NextHopVirtualAppliance.Tests.ps1](./tests/Deny-Route-NextHopVirtualAppliance.Tests.ps1).
- Policies currently do not trigger on DELETE only PUT and PATCH requests. Hence deleted resources can only be remediated asynchronously by using a remediation task.
- Accessing shared resources during your tests can cause race conditions, e.g. parallel test runs. Consider creating a dedicated resource group per test case to be a best practice. [AzTest](./utils/Test.Utils.psm1) can automatically create and delete a resource group for you:

```powershell
 It "..." -Tag "..." {
    AzTest -ResourceGroup {
        param($ResourceGroup)
       
        # ...
    }
}
```

### Can we execute the tests on our local machines?
Just like in your DevOps pipeline of choice, you can execute the tests on your local machines as well, e.g.:

```powershell
Invoke-Pester -Output Detailed
```

### Is it possible to execute just a subset of the tests?
You can leverage tags to execute just a subset of the tests, e.g.:

```powershell
Invoke-Pester -Output Detailed -Tags "tag"

It "..." -Tag "tag" {
    # ...
}
```

### Is it possible to execute the tests under a different user?
Yes you can. Just use different ```AZURE_CREDENTIALS``` to login before you execute the tests. Additionally, you can tag the tests by user and select them accordingly when running them in your DevOps pipeline or locally.

```yaml
- name: Login to Azure
  uses: azure/login@v1
  with:
    creds: ${{secrets.AZURE_CREDENTIALS}}
    enable-AzPSSession: true 
- name: Test Azure Policies
  shell: pwsh
  run: |
    Invoke-Pester -Output Detailed -CI -Tags "user"
```

```powershell
It "..." -Tag "user" {
    # ...
}
```

> Do not mix testing Azure Policy and RBAC. If you need to test RBAC e.g., to validate custom roles, create dedicated PowerShell scripts in the [tests](./tests/) folder. This separation helps you to keep your test maintainable by not mixing different concerns.

### Can we pass parameters to our tests?
Yes you can. Starting with [Pester 5.1.0-beta2](https://www.powershellgallery.com/packages/Pester/) passing parameters is supported (See: [GitHub Issue #1485](https://github.com/pester/Pester/issues/1485)):

```powershell
$container = @(
    (New-TestContainer -Path $file -Data @{ Value = 1 })
    (New-TestContainer -Path $file -Data @{ Value = 2 })
)
$r = Invoke-Pester -Container $container -PassThru
```

### The tests take a long time to complete, can we speed things up?
Pester itself currently does not natively support it (See [GitHub Issue #1270](https://github.com/pester/Pester/issues/1270)), but you can achieve parallelization by invoking Pester multiple times:

```powershell
$job = Get-ChildItem -Path "./tests" -Exclude "*.psm1" 
| ForEach-Object -Parallel { 
    Invoke-Pester -Path $_ -Output None -PassThru -CI  
} -ThrottleLimit 10 -AsJob
$testResults = $job | Wait-Job | Receive-Job  
```

Please consider above as sample code to give you an idea how to parallelize your tests. Parallelization is a future topic to cover in case there is enough community interest. Just as a side note, each job in a GitHub workflow can run for up to 6 hours of execution time. Following, your tests should finish before that or you can split them into multiple jobs, since GitHub workflows can run up to 72 hours. Avoid accessing shared resources when parallelizing test execution to avoid race conditions. Instead create a dedicated resource group per test case i.e., [AzTest](./utils/Test.Utils.psm1) can automatically create and delete a resource group for you:

```powershell
 It "..." -Tag "..." {
    AzTest -ResourceGroup {
        param($ResourceGroup)
       
        # ...
    }
}
```


### Should we execute the tests to validate a pull request?
Executing the tests can take a few minutes up to some hours. The long duration is mainly caused by waiting for policy compliance scans and remediations to complete. So while you certainly can execute the tests to validate your pull request, it is not advisable since a pull request should provide your developers feedback in just a couple of minutes to reduce their unproductive waiting time. That being said, executing them as part of your [continuous integration](https://martinfowler.com/articles/continuousIntegration.html) on the main branch is what you should aim for. Alternatively, it might be just good enough to schedule a test run once a day.

### Why did you assign the policies to subscription and not management group scope?
Mainly to reduce complexity when explaining the approach and to ease setting it up in your Azure environment. While the approach can easily be scaled towards supporting management groups, the focus lies on testing policies. If you want to learn more about managing Azure at scale, checkout [Enterprise Scale](https://github.com/Azure/Enterprise-Scale).

### Can we scale this testing approach towards a complex management group hierarchy?
You can try to scale towards a more complex management group hierarchy like this (See: [Enterprise Scale](https://github.com/Azure/Enterprise-Scale/blob/main/docs/reference/adventureworks/README.md)):

![Complex management group hierarchy](./docs/azure-management-groups.png)

An idea would be to create an Azure subscription for testing per leaf management group, so referring to the example management group hierarchy: Management, Connectivity, Identity, Corp and Online. For each of this subscriptions you would run a set of tests. The tests are encapsulated in dedicated PowerShell modules per policy, so you could reuse them across subscriptions. While this certainly improves test coverage by also considering policy layering (See: [Layering policy definitions
](https://docs.microsoft.com/en-us/azure/governance/policy/concepts/effects#layering-policy-definitions)), it also increases the test duration and complexity a lot. If you are just interested in validating the logic of a single policy, scaling the approach towards a complex management group hierarchy might be overkill.
