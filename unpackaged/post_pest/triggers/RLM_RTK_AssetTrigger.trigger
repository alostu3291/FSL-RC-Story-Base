trigger RLM_RTK_AssetTrigger on Asset (after insert, after update) {
    RLM_RTK_Coverage.assetsChanged(Trigger.new);
}
