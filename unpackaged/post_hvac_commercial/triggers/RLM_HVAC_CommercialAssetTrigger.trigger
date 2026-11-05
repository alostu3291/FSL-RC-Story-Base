trigger RLM_HVAC_CommercialAssetTrigger on Asset (after insert, after update) {
    if (Trigger.isInsert) {
        RLM_HVAC_CommercialCoverage.assetsInserted(Trigger.new);
    } else {
        RLM_HVAC_CommercialCoverage.assetsUpdated(Trigger.new, Trigger.oldMap);
    }
}
