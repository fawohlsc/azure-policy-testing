Import-Module "$($($PSScriptRoot))/Policy.Utils.psm1" -Force

Describe "Testing Azure Policies" {
    BeforeEach {
        # Suppress unused variable warning caused by Pester scoping.
        # See also: https://pester.dev/docs/usage/setup-and-teardown#scoping
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        
        # Create a dedicated resource group for each test case
        $ResourceGroup = New-AzResourceGroup -Name (New-Guid).Guid -Location "northeurope"
    }

    Context "When route table is created" -Tag route-table-create {
        It "Should append route pointing to the virtual appliance (Policy: Append-Route-NextHopVirtualAppliance)" {
            # Create route table
            $routeTableName = "route-table"
            New-AzRouteTable `
                -Name $routeTableName `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location
            
            # Verify that route pointing to the virtual appliance was appended by policy
            Get-AzRouteTable -ResourceGroupName $ResourceGroup.ResourceGroupName -Name $routeTableName
            | Test-RouteNextHopVirtualAppliance
            | Should -BeTrue
        }
    }

    Context "When route is deleted" -Tag route-delete {
        It "Should audit route pointing to the virtual appliance (Audit-Route-NextHopVirtualAppliance)" {
            # Create route table and remove route pointing to the virtual appliance, which was appended by policy
            $routeTableName = "route-table"
            $routeTable = New-AzRouteTable `
                -Name $routeTableName `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location
            | Remove-RouteNextHopVirtualAppliance

            # Trigger compliance scan for resource group and wait for completion
            $ResourceGroup | Complete-PolicyComplianceScan 

            # Verify that route table is incompliant
            $routeTable 
            | Get-PolicyComplianceState -PolicyName "Audit-Route-NextHopVirtualAppliance"
            | Should -BeFalse
        }
        It "Should remediate route pointing to the virtual appliance (Policy: Deploy-Route-NextHopVirtualAppliance)" {
            # Create route table and remove route pointing to the virtual appliance, which was appended by policy
            $routeTableName = "route-table"
            New-AzRouteTable `
                -Name $routeTableName `
                -ResourceGroupName $ResourceGroup.ResourceGroupName `
                -Location $ResourceGroup.Location
            | Remove-RouteNextHopVirtualAppliance
            
            # Remediate resource group and wait for completion
            $ResourceGroup | Complete-PolicyRemediation -PolicyName "Deploy-Route-NextHopVirtualAppliance"
            
            # Verify that removed route pointing to the virtual appliance was remediated by policy
            Get-AzRouteTable -ResourceGroupName $ResourceGroup.ResourceGroupName -Name $routeTableName
            | Test-RouteNextHopVirtualAppliance
            | Should -BeTrue
        }
    }

    AfterEach {
        Remove-AzResourceGroup -Name $ResourceGroup.ResourceGroupName -Force
    }
}

