trigger RLM_RTK_WorkOrderTrigger on WorkOrder (before insert, before update, after update) {
    if (Trigger.isBefore) {
        RLM_RTK_Coverage.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
    } else {
        RLM_RTK_Coverage.afterUpdate(Trigger.new, Trigger.oldMap);
    }
}
