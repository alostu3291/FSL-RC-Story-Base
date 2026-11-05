trigger RLM_HVAC_CommercialWorkOrderTrigger on WorkOrder (before insert) {
    RLM_HVAC_CommercialCoverage.fillVisitDefaults(Trigger.new);
}
