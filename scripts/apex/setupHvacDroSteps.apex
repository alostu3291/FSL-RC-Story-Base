// Idempotent Brightline DRO step definitions for the Initial Tune-up and Replacement Install paths.
// StepType picklist values in this org are AutoTask / ManualTask / Milestone (not "Field Installation").
Id userId = UserInfo.getUserId();

// Step name => group, step type, flow (blank for none)
Map<String, List<String>> STEPS = new Map<String, List<String>>{
    'Create Initial Tune-up Work Order' => new List<String>{ 'Initial Tune-up', 'AutoTask', 'RLM_HVAC_Create_Initial_Work_Order' },
    'Initial Tune-up Complete' => new List<String>{ 'Initial Tune-up', 'ManualTask', '' },
    'Start Agreement Billing' => new List<String>{ 'HVAC Finance', 'Milestone', '' },
    'Create Replacement Install Work Order' => new List<String>{ 'Replacement Install', 'AutoTask', 'RLM_HVAC_Create_Install_Work_Order' },
    'Replacement Install Complete' => new List<String>{ 'Replacement Install', 'ManualTask', '' }
};
// Dependency name => step, depends on
Map<String, List<String>> DEPENDENCIES = new Map<String, List<String>>{
    'Create WO to Tune-up Complete' => new List<String>{ 'Initial Tune-up Complete', 'Create Initial Tune-up Work Order' },
    'Tune-up Complete to Bill' => new List<String>{ 'Start Agreement Billing', 'Initial Tune-up Complete' },
    'Create WO to Install Complete' => new List<String>{ 'Replacement Install Complete', 'Create Replacement Install Work Order' }
};
// Fulfillment product => group its scenarios use
Map<String, String> SCENARIO_GROUPS = new Map<String, String>{
    'HVAC-DRO-FSL' => 'Initial Tune-up',
    'HVAC-DRO-INSTALL' => 'Replacement Install'
};

Map<String, Id> groups = new Map<String, Id>();
for (FulfillmentStepDefinitionGroup g : [
    SELECT Id, Name FROM FulfillmentStepDefinitionGroup
    WHERE Name IN ('Initial Tune-up', 'HVAC Finance', 'Replacement Install')
]) {
    groups.put(g.Name, g.Id);
}
if (groups.size() < 3) {
    System.debug('Missing HVAC fulfillment step groups; run insert_hvac_dro_fsl_data first');
} else {
    Map<String, FulfillmentStepDefinition> byName = new Map<String, FulfillmentStepDefinition>();
    for (FulfillmentStepDefinition s : [
        SELECT Id, Name, FlowDefinitionName FROM FulfillmentStepDefinition WHERE Name IN :STEPS.keySet()
    ]) {
        byName.put(s.Name, s);
    }

    List<FulfillmentStepDefinition> toInsert = new List<FulfillmentStepDefinition>();
    List<FulfillmentStepDefinition> toUpdate = new List<FulfillmentStepDefinition>();
    for (String name : STEPS.keySet()) {
        List<String> d = STEPS.get(name);
        String flowName = String.isBlank(d[2]) ? null : d[2];
        FulfillmentStepDefinition existing = byName.get(name);
        if (existing == null) {
            toInsert.add(new FulfillmentStepDefinition(
                Name = name,
                StepDefinitionGroupId = groups.get(d[0]),
                AssignedToId = userId,
                FlowDefinitionName = flowName,
                ForcePlanFreezeDuringExecution = 'Never',
                IsSkipBranch = false,
                Scope = 'Plan',
                StepType = d[1],
                UsageType = 'Fulfillment'
            ));
        } else if (flowName != null && existing.FlowDefinitionName != flowName) {
            existing.FlowDefinitionName = flowName;
            toUpdate.add(existing);
        }
    }
    insert toInsert;
    update toUpdate;

    Map<String, Id> stepIds = new Map<String, Id>();
    for (FulfillmentStepDefinition s : [SELECT Id, Name FROM FulfillmentStepDefinition WHERE Name IN :STEPS.keySet()]) {
        stepIds.put(s.Name, s.Id);
    }

    Set<String> existingDeps = new Set<String>();
    for (FulfillmentStepDependencyDef d : [
        SELECT Name FROM FulfillmentStepDependencyDef WHERE Name IN :DEPENDENCIES.keySet()
    ]) {
        existingDeps.add(d.Name);
    }
    List<FulfillmentStepDependencyDef> deps = new List<FulfillmentStepDependencyDef>();
    for (String name : DEPENDENCIES.keySet()) {
        if (existingDeps.contains(name)) {
            continue;
        }
        List<String> d = DEPENDENCIES.get(name);
        deps.add(new FulfillmentStepDependencyDef(
            Name = name,
            DependencyScope = 'Plan',
            FulfillmentStepDefinitionId = stepIds.get(d[0]),
            DependsOnStepDefinitionId = stepIds.get(d[1]),
            IsCompensateInReverse = false
        ));
    }
    insert deps;

    List<ProductFulfillmentScenario> scenarios = new List<ProductFulfillmentScenario>();
    for (ProductFulfillmentScenario sc : [
        SELECT Id, FulfillmentStepDefnGroupId, Product.StockKeepingUnit FROM ProductFulfillmentScenario
        WHERE Product.StockKeepingUnit IN :SCENARIO_GROUPS.keySet()
    ]) {
        Id groupId = groups.get(SCENARIO_GROUPS.get(sc.Product.StockKeepingUnit));
        if (sc.FulfillmentStepDefnGroupId != groupId) {
            sc.FulfillmentStepDefnGroupId = groupId;
            scenarios.add(sc);
        }
    }
    update scenarios;
    System.debug('setupHvacDroSteps complete');
}
