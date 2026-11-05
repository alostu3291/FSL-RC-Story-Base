// Resets the Brightline Commercial capital project story for a property group so Capital Project can
// propose the rooftop unit replacement again. Run through the reset_hvac_capital_project task; param1 is
// the group's site code (LPG-HQ when blank).
//  - Open (unbooked) project quotes are marked Rejected, so a new proposal isn't blocked.
//  - Open crane, install and commissioning work orders of booked projects are canceled with their
//    appointments. Booked orders, invoices and billing schedules stay; they're the history.
//  - Units a completed install rewrote get their original install year and refrigerant back, from
//    the "previous unit was installed in <year> with <lb> lb of <refrigerant>" note the install wrote.

String groupCode = String.isBlank('%%%PARAM_1%%%') ? 'LPG-HQ' : '%%%PARAM_1%%%';
List<Account> groups = [SELECT Id, Name FROM Account WHERE RLM_HVAC_Site_Code__c = :groupCode AND ParentId = null LIMIT 1];
if (groups.isEmpty()) {
    throw new IllegalArgumentException('No property group with site code ' + groupCode + '. Run seed_hvac_commercial_sites first.');
}
Account grp = groups[0];
Set<Id> siteIds = new Map<Id, Account>([SELECT Id FROM Account WHERE ParentId = :grp.Id]).keySet();

Set<Id> openQuoteIds = new Set<Id>();
for (QuoteLineItem line : [
    SELECT QuoteId FROM QuoteLineItem
    WHERE Quote.QuoteAccountId = :grp.Id AND Product2.StockKeepingUnit = :RLM_HVAC_CapitalProject.REPLACEMENT_SKU
        AND Quote.Status NOT IN ('Accepted', 'Rejected', 'Denied')
]) {
    openQuoteIds.add(line.QuoteId);
}
List<Quote> rejected = new List<Quote>();
for (Id quoteId : openQuoteIds) {
    rejected.add(new Quote(Id = quoteId, Status = 'Rejected'));
}
update rejected;

Map<Id, WorkOrder> steps = new Map<Id, WorkOrder>([
    SELECT Id FROM WorkOrder
    WHERE AccountId IN :siteIds AND RLM_Order__c != null AND RLM_Fulfillment_Step__c != null
        AND Status NOT IN ('Completed', 'Closed', 'Canceled', 'Cannot Complete')
]);
List<ServiceAppointment> stepVisits = [
    SELECT Id FROM ServiceAppointment
    WHERE ParentRecordId IN :steps.keySet() AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
];
for (ServiceAppointment sa : stepVisits) {
    sa.Status = 'Canceled';
}
update stepVisits;
for (WorkOrder wo : steps.values()) {
    wo.Status = 'Canceled';
}
update steps.values();

Pattern previous = Pattern.compile('previous unit was installed in (\\d{4}) with ([\\d.]+) lb of ([^.]+)\\.');
List<Asset> restored = new List<Asset>();
for (Asset a : [
    SELECT Id, Description FROM Asset
    WHERE AccountId IN :siteIds AND RLM_HVAC_Tonnage__c != null
]) {
    if (a.Description == null || !a.Description.startsWith('Replaced ')) {
        continue;
    }
    Matcher m = previous.matcher(a.Description);
    if (!m.find()) {
        continue;
    }
    Integer year = Integer.valueOf(m.group(1));
    restored.add(new Asset(Id = a.Id, RLM_HVAC_Install_Year__c = year, RLM_HVAC_Refrigerant_Charge__c = Decimal.valueOf(m.group(2)),
        RLM_HVAC_Refrigerant_Type__c = m.group(3), InstallDate = Date.newInstance(year, 5, 1), Status = 'Installed',
        Description = null));
}
update restored;

System.debug('resetHvacCapitalProject ' + grp.Name + ': rejected quotes=' + rejected.size() + ', canceled steps='
    + steps.size() + ', restored units=' + restored.size());
