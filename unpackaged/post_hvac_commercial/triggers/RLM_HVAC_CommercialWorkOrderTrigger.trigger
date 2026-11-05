trigger RLM_HVAC_CommercialWorkOrderTrigger on WorkOrder (before insert, after update) {
    if (Trigger.isInsert) {
        RLM_HVAC_CommercialCoverage.fillVisitDefaults(Trigger.new);
    } else {
        RLM_HVAC_CapitalProject.workOrdersUpdated(Trigger.new, Trigger.oldMap);
        RLM_HVAC_RefrigerantCompliance.workOrdersUpdated(Trigger.new, Trigger.oldMap);
    }
}
