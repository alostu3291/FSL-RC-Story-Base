trigger RLM_HVAC_WorkOrderTrigger on WorkOrder (before insert, before update, after update) {
    if (Trigger.isBefore) {
        RLM_HVAC_Coverage.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    } else {
        RLM_HVAC_Coverage.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
