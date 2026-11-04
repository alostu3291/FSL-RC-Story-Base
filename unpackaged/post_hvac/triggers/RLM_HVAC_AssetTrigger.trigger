trigger RLM_HVAC_AssetTrigger on Asset (after insert, after update) {
    RLM_HVAC_Coverage.assetsChanged(Trigger.new);
}
