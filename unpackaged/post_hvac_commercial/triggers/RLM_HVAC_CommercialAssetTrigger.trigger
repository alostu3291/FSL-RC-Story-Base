trigger RLM_HVAC_CommercialAssetTrigger on Asset (after insert) {
    RLM_HVAC_CommercialCoverage.assetsInserted(Trigger.new);
}
