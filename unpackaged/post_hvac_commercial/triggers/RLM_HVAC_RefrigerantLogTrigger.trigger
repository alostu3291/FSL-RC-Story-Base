trigger RLM_HVAC_RefrigerantLogTrigger on RLM_HVAC_Refrigerant_Log__c (before insert, after insert) {
    if (Trigger.isBefore) {
        RLM_HVAC_RefrigerantCompliance.logsInserting(Trigger.new);
    } else {
        RLM_HVAC_RefrigerantCompliance.logsInserted(Trigger.new);
    }
}
