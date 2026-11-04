// Delete Brightline HVAC demo configuration data (not transactional quotes/orders).
// Dependency order: coverage → junctions → work types/territory → related components → price book → products → zones.

List<MaintenancePlan> plans = [SELECT Id FROM MaintenancePlan WHERE MaintenancePlanTitle = :RLM_HVAC_Coverage.PLAN_TITLE];
delete [SELECT Id FROM WorkOrder WHERE MaintenancePlanId IN :plans AND Status = 'New'];
delete plans;
delete [SELECT Id FROM Entitlement WHERE RLM_HVAC_Covered_Systems__c != null];

List<WorkType> workTypes = [
    SELECT Id FROM WorkType
    WHERE Name IN ('System Check', 'Initial Tune-up', 'Spring AC Tune-up', 'Fall Furnace Tune-up',
        'Indoor Air Quality Visit', 'Water Heater Flush', 'No-Cool / No-Heat Call', 'Repair', 'Replacement Install')
];
if (!workTypes.isEmpty()) {
    delete [SELECT Id FROM SkillRequirement WHERE RelatedRecordId IN :workTypes];
}

ServiceTerritory territory;
List<ServiceTerritory> territories = [SELECT Id FROM ServiceTerritory WHERE Name = 'Naperville IL' LIMIT 1];
if (!territories.isEmpty()) {
    territory = territories[0];
    delete [SELECT Id FROM ServiceTerritoryMember WHERE ServiceTerritoryId = :territory.Id];
    delete territory;
}

List<OperatingHours> hours = [SELECT Id FROM OperatingHours WHERE Name = 'Naperville Service Hours' LIMIT 1];
if (!hours.isEmpty()) {
    delete [SELECT Id FROM TimeSlot WHERE OperatingHoursId = :hours[0].Id];
    delete hours;
}

delete workTypes;

List<Product2> products = [SELECT Id FROM Product2 WHERE StockKeepingUnit LIKE 'HVAC-%'];
if (!products.isEmpty()) {
    delete [
        SELECT Id FROM ProductFulfillmentScenario WHERE ProductId IN :products
    ];
    delete [
        SELECT Id FROM ProductFulfillmentDecompRule
        WHERE SourceProductId IN :products OR DestinationProductId IN :products
    ];
    delete [SELECT Id FROM ProductRelatedComponent WHERE ParentProductId IN :products OR ChildProductId IN :products];
    delete [SELECT Id FROM ProductCategoryProduct WHERE ProductId IN :products];
    delete [SELECT Id FROM ProductAttributeDefinition WHERE Product2Id IN :products];
    delete [SELECT Id FROM ProductSellingModelOption WHERE Product2Id IN :products];
    delete [SELECT Id FROM PricebookEntry WHERE Product2Id IN :products];
    delete products;
}

delete [SELECT Id FROM ProductCategory WHERE Code LIKE 'PC-HVAC-%'];
delete [SELECT Id FROM ProductCatalog WHERE Code = 'CAT-HVAC-RES'];
delete [SELECT Id FROM RLM_HVAC_Service_Zone__c];
delete [SELECT Id FROM FulfillmentStepDependencyDef
    WHERE Name IN ('Create WO to Tune-up Complete', 'Tune-up Complete to Bill', 'Create WO to Install Complete')];
delete [SELECT Id FROM FulfillmentStepDefinition
    WHERE StepDefinitionGroup.Name IN ('Initial Tune-up', 'HVAC Finance', 'Replacement Install')];
delete [SELECT Id FROM FulfillmentStepDefinitionGroup WHERE Name IN ('Initial Tune-up', 'HVAC Finance', 'Replacement Install')];

System.debug('deleteHvacData complete');
