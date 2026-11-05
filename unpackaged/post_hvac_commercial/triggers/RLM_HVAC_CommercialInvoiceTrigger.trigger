trigger RLM_HVAC_CommercialInvoiceTrigger on Invoice (after insert) {
    RLM_HVAC_ContractInvoice.invoicesInserted(Trigger.new);
}
