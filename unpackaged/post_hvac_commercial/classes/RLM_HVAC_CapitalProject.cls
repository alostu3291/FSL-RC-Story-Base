/**
 * Brightline Commercial capital projects: replacing a site's aging rooftop units.
 *
 * The project quote has the replacements and a crane lift for the install day, on the property
 * group's account so it bills to HQ. Both products bill on the Capital Project milestone treatment:
 * 40% when the project is booked, 40% when the units are installed and 20% at commissioning.
 * Booking activates the order and releases the deposit. The order's fulfillment plan (DRO) then runs
 * three steps in turn, each a work order at the site that this class creates for the step's flow:
 * crane lift, install (a line per unit) and commissioning (a line per new unit). Completing a work
 * order completes its step (RLM_FSL_Complete_Fulfillment_Step); the install and commissioning
 * work orders also accomplish the milestone with their step's name and invoice the order here,
 * since that flow only invoices schedules still waiting on a milestone when the work order completes.
 * Completing the install updates each unit in place, so the site's maintenance plan keeps it.
 */
public with sharing class RLM_HVAC_CapitalProject {
    public static final String REPLACEMENT_SKU = 'HVAC-COM-RTU-REPL';
    public static final String CRANE_SKU = 'HVAC-COM-CRANE';
    /** The catalog's replacement unit. */
    public static final Decimal REPLACEMENT_TONS = 10;
    public static final String NEW_REFRIGERANT = 'R-454B';
    public static final Integer REPLACE_AT_AGE = 15;
    public static final String PHASED_OUT_REFRIGERANT = 'R-22';
    public static final String DEPOSIT = 'Project Deposit';
    public static final String CRANE_DONE = 'Crane Lift Complete';
    public static final String INSTALL_DONE = 'Rooftop Install Complete';
    public static final String COMMISSIONING_DONE = 'Commissioning Complete';
    /** Milestone => share of the project, in billing order; matches setupHvacCommercialRevenue. */
    public static final Map<String, Decimal> MILESTONES = new Map<String, Decimal>{
        DEPOSIT => 40, INSTALL_DONE => 40, COMMISSIONING_DONE => 20
    };
    /** Stage => the step its work order completes, the work type, the work order subject. */
    private static final Map<String, List<String>> STAGES = new Map<String, List<String>>{
        'Crane Lift' => new List<String>{ CRANE_DONE, 'Commercial Crane Lift', 'Crane lift' },
        'Install' => new List<String>{ INSTALL_DONE, 'Commercial RTU Replacement', 'Rooftop unit replacement' },
        'Commissioning' => new List<String>{ COMMISSIONING_DONE, 'Commercial RTU Commissioning', 'Commissioning' }
    };
    private static final Integer DEPOSIT_DELAY_MINUTES = 1;
    private static final Integer DEPOSIT_ATTEMPTS = 5;

    public class Unit {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String tag;
        @AuraEnabled public Decimal tons;
        @AuraEnabled public Integer installYear;
        @AuraEnabled public Integer age;
        @AuraEnabled public String refrigerant;
        @AuraEnabled public Decimal charge;
        @AuraEnabled public Boolean eligible = false;
        @AuraEnabled public Boolean recommended = false;
        @AuraEnabled public String reason;
    }

    public class SiteOption {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public Integer recommended = 0;
    }

    public class Milestone {
        @AuraEnabled public String name;
        @AuraEnabled public Decimal percent;
        @AuraEnabled public Decimal amount = 0;
        @AuraEnabled public Boolean accomplished = false;
    }

    public class Proposal {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public Id siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public List<SiteOption> sites = new List<SiteOption>();
        @AuraEnabled public List<Unit> units = new List<Unit>();
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal cranePrice;
        @AuraEnabled public List<Milestone> milestones = new List<Milestone>();
        @AuraEnabled public Id openQuoteId;
        @AuraEnabled public String openQuoteName;
    }

    public class Step {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Boolean done = false;
        @AuraEnabled public Id workOrderId;
        @AuraEnabled public String workOrderNumber;
        @AuraEnabled public String workOrderStatus;
        @AuraEnabled public Datetime scheduledStart;
        @AuraEnabled public Integer lines = 0;
    }

    public class InvoiceRef {
        @AuraEnabled public Id invoiceId;
        @AuraEnabled public String documentNumber;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public Decimal charge = 0;
        @AuraEnabled public Decimal total = 0;
    }

    public class Status {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteName;
        @AuraEnabled public String quoteStatus;
        @AuraEnabled public Boolean isProject = false;
        @AuraEnabled public String poNumber;
        @AuraEnabled public String siteName;
        @AuraEnabled public Integer unitCount = 0;
        @AuraEnabled public Decimal total = 0;
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String orderStatus = 'None';
        @AuraEnabled public List<Step> steps = new List<Step>();
        @AuraEnabled public List<Milestone> milestones = new List<Milestone>();
        @AuraEnabled public List<InvoiceRef> invoices = new List<InvoiceRef>();
        @AuraEnabled public Decimal invoiced = 0;
    }

    /** Product SKUs are unique org-wide, so tests can't create the catalog's price book entries. */
    @TestVisible
    private static Map<String, Decimal> testPrices;

    // ---------------------------------------------------------------- proposal and quote

    /** The site's units with the ones due for replacement; recordId is the group or a site. */
    @AuraEnabled
    public static Proposal proposal(Id recordId, Id siteId) {
        try {
            return proposalFor(recordId, siteId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static Proposal proposalFor(Id recordId, Id siteId) {
        Account record = [SELECT Id, ParentId FROM Account WHERE Id = :recordId];
        Account grp = [SELECT Id, Name FROM Account WHERE Id = :(record.ParentId != null ? record.ParentId : record.Id)];
        Proposal p = new Proposal();
        p.groupId = grp.Id;
        p.groupName = grp.Name;
        Map<Id, Account> sites = new Map<Id, Account>([
            SELECT Id, Name FROM Account WHERE ParentId = :grp.Id ORDER BY RLM_HVAC_Site_Code__c NULLS LAST, Name
        ]);
        Map<Id, List<Unit>> unitsBySite = new Map<Id, List<Unit>>();
        for (Asset a : [
            SELECT Id, AccountId, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Tonnage__c, RLM_HVAC_Install_Year__c,
                RLM_HVAC_Refrigerant_Type__c, RLM_HVAC_Refrigerant_Charge__c
            FROM Asset
            WHERE AccountId IN :sites.keySet() AND RLM_HVAC_Tonnage__c != null AND Status != 'Obsolete'
            ORDER BY RLM_HVAC_Unit_Tag__c
        ]) {
            if (!unitsBySite.containsKey(a.AccountId)) {
                unitsBySite.put(a.AccountId, new List<Unit>());
            }
            unitsBySite.get(a.AccountId).add(unitFor(a, Date.today().year()));
        }
        SiteOption best;
        for (Account site : sites.values()) {
            List<Unit> units = unitsBySite.get(site.Id);
            if (units == null) {
                continue;
            }
            SiteOption o = new SiteOption();
            o.accountId = site.Id;
            o.name = site.Name;
            for (Unit u : units) {
                if (u.recommended) {
                    o.recommended++;
                }
            }
            p.sites.add(o);
            if (best == null || o.recommended > best.recommended) {
                best = o;
            }
        }
        Id chosen = siteId != null && sites.containsKey(siteId) ? siteId
            : (sites.containsKey(record.Id) ? record.Id : best?.accountId);
        if (chosen != null) {
            p.siteId = chosen;
            p.siteName = sites.get(chosen).Name;
            p.units = unitsBySite.get(chosen) ?? new List<Unit>();
        }
        Map<String, Decimal> prices = prices();
        p.unitPrice = prices.get(REPLACEMENT_SKU);
        p.cranePrice = prices.get(CRANE_SKU);
        for (String name : MILESTONES.keySet()) {
            Milestone m = new Milestone();
            m.name = name;
            m.percent = MILESTONES.get(name);
            p.milestones.add(m);
        }
        for (QuoteLineItem line : [
            SELECT QuoteId, Quote.Name FROM QuoteLineItem
            WHERE Quote.QuoteAccountId = :grp.Id AND Product2.StockKeepingUnit = :REPLACEMENT_SKU
                AND RLM_HVAC_Site__c = :chosen AND Quote.Status NOT IN ('Accepted', 'Rejected', 'Denied')
            ORDER BY Quote.CreatedDate DESC LIMIT 1
        ]) {
            p.openQuoteId = line.QuoteId;
            p.openQuoteName = line.Quote.Name;
        }
        return p;
    }

    @TestVisible
    private static Unit unitFor(Asset a, Integer thisYear) {
        Unit u = new Unit();
        u.assetId = a.Id;
        u.tag = a.RLM_HVAC_Unit_Tag__c;
        u.tons = a.RLM_HVAC_Tonnage__c;
        u.installYear = a.RLM_HVAC_Install_Year__c == null ? null : a.RLM_HVAC_Install_Year__c.intValue();
        u.age = u.installYear == null ? null : thisYear - u.installYear;
        u.refrigerant = a.RLM_HVAC_Refrigerant_Type__c;
        u.charge = a.RLM_HVAC_Refrigerant_Charge__c;
        u.eligible = u.tons == REPLACEMENT_TONS;
        List<String> reasons = new List<String>();
        if (u.refrigerant == PHASED_OUT_REFRIGERANT) {
            reasons.add(PHASED_OUT_REFRIGERANT + ' is phased out');
        }
        if (u.age != null && u.age >= REPLACE_AT_AGE) {
            reasons.add(u.age + ' years old');
        }
        u.recommended = u.eligible && !reasons.isEmpty();
        u.reason = u.eligible ? String.join(reasons, ', ') : 'No replacement priced for ' + u.tons.stripTrailingZeros().toPlainString() + ' tons';
        return u;
    }

    private static Map<String, Decimal> prices() {
        Map<String, Decimal> prices = new Map<String, Decimal>();
        for (PricebookEntry e : [
            SELECT UnitPrice, Product2.StockKeepingUnit FROM PricebookEntry
            WHERE Product2.StockKeepingUnit IN (:REPLACEMENT_SKU, :CRANE_SKU) AND Pricebook2.IsStandard = true
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            prices.put(e.Product2.StockKeepingUnit, e.UnitPrice);
        }
        if (testPrices != null) {
            prices.putAll(testPrices);
        }
        return prices;
    }

    /** One quote for the site's replacements and the crane lift, on the group's account. */
    @AuraEnabled
    public static Id createQuote(Id siteId, List<Id> unitIds) {
        try {
            return createQuoteFor(siteId, unitIds);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static Id createQuoteFor(Id siteId, List<Id> unitIds) {
        Proposal p = proposalFor(siteId, siteId);
        Set<Id> wanted = new Set<Id>(unitIds ?? new List<Id>());
        List<String> tags = new List<String>();
        for (Unit u : p.units) {
            if (wanted.contains(u.assetId)) {
                if (!u.eligible) {
                    throw new ProjectException(u.tag + ': ' + u.reason + '.');
                }
                tags.add(u.tag);
            }
        }
        if (tags.isEmpty()) {
            throw new ProjectException('Pick the units to replace.');
        }
        if (p.openQuoteId != null) {
            throw new ProjectException('Project quote ' + p.openQuoteName + ' is already open for ' + p.siteName + '.');
        }
        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry e : [
            SELECT Id, Product2Id, Pricebook2Id, UnitPrice, Product2.StockKeepingUnit FROM PricebookEntry
            WHERE Product2.StockKeepingUnit IN (:REPLACEMENT_SKU, :CRANE_SKU) AND Pricebook2.IsStandard = true
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            entries.put(e.Product2.StockKeepingUnit, e);
        }
        if (!entries.containsKey(REPLACEMENT_SKU) || !entries.containsKey(CRANE_SKU)) {
            throw new ProjectException('Missing a price for the replacement or the crane lift; run setup_hvac_commercial_revenue.');
        }
        Account site = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
            FROM Account WHERE Id = :p.siteId
        ];
        String name = (site.Name + ' - Rooftop Unit Replacement').left(80);
        Opportunity opportunity = new Opportunity(Name = name, AccountId = p.groupId, StageName = 'Proposal/Price Quote',
            CloseDate = Date.today().addDays(30));
        try {
            insert opportunity;
        } catch (DmlException e) {
            opportunity.StageName = 'Qualification';
            insert opportunity;
        }
        Contact signer;
        for (Contact c : [SELECT Id, Title FROM Contact WHERE AccountId = :p.groupId ORDER BY CreatedDate]) {
            if (signer == null && c.Title != null && c.Title.containsIgnoreCase('Facilit')) {
                signer = c;
            }
        }

        RevSalesTrxn.RecordResource quote = new RevSalesTrxn.RecordResource(Quote.SObjectType, 'POST');
        quote.fieldValues = new Map<String, Object>{
            'Name' => name,
            'OpportunityId' => opportunity.Id,
            'QuoteAccountId' => p.groupId,
            'Pricebook2Id' => entries.get(REPLACEMENT_SKU).Pricebook2Id,
            'CurrencyIsoCode' => 'USD',
            'RLM_Line_of_Business__c' => RLM_HVAC_CommercialPricing.LOB,
            'RLM_Payment_Terms__c' => RLM_HVAC_CommercialPricing.PAYMENT_TERMS,
            'ExpirationDate' => String.valueOf(Date.today().addDays(30)),
            'Description' => (tags.size() + ' rooftop units replaced at ' + site.Name + ': ' + String.join(tags, ', ')
                + '. Billed 40% at booking, 40% at install and 20% at commissioning.').abbreviate(255),
            'ShippingStreet' => site.BillingStreet,
            'ShippingCity' => site.BillingCity,
            'ShippingState' => site.BillingState,
            'ShippingPostalCode' => site.BillingPostalCode,
            'ShippingCountry' => site.BillingCountry
        };
        if (signer != null) {
            quote.fieldValues.put('ContactId', signer.Id);
        }
        RevSalesTrxn.RecordResource grp = new RevSalesTrxn.RecordResource(QuoteLineGroup.SObjectType, 'POST');
        grp.fieldValues = new Map<String, Object>{
            'QuoteId' => '@{refQuote.id}', 'Name' => site.Name, 'SortOrder' => '1',
            'Description' => (tags.size() + ' units, ' + (REPLACEMENT_TONS * tags.size()).stripTrailingZeros().toPlainString()
                + ' tons, ' + NEW_REFRIGERANT).abbreviate(255)
        };
        List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
            new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quote),
            new RevSalesTrxn.RecordWithReferenceRequest('refGroup', grp),
            new RevSalesTrxn.RecordWithReferenceRequest('refUnits',
                line(entries.get(REPLACEMENT_SKU), tags.size(), site.Id, String.join(tags, ', '))),
            new RevSalesTrxn.RecordWithReferenceRequest('refCrane',
                line(entries.get(CRANE_SKU), 1, site.Id, 'Install day at ' + site.Name))
        };
        RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
            new RevSalesTrxn.GraphRequest('hvacCapitalProject', records),
            RevSalesTrxn.PricingPreferenceEnum.SYSTEM, RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput(), null, null, RevSalesTrxn.TaxPreferenceEnum.SKIP, null);
        if (response == null || response.isSuccess != true || String.isBlank(response.salesTransactionId)) {
            throw new ProjectException('Place Sales Transaction failed: '
                + (response == null ? 'null' : JSON.serialize(response.errorResponse)));
        }
        return response.salesTransactionId;
    }

    private static RevSalesTrxn.RecordResource line(PricebookEntry entry, Integer quantity, Id siteId, String description) {
        RevSalesTrxn.RecordResource qli = new RevSalesTrxn.RecordResource(QuoteLineItem.SObjectType, 'POST');
        qli.fieldValues = new Map<String, Object>{
            'QuoteId' => '@{refQuote.id}',
            'QuoteLineGroupId' => '@{refGroup.id}',
            'Product2Id' => entry.Product2Id,
            'PricebookEntryId' => entry.Id,
            'Quantity' => String.valueOf(quantity),
            'UnitPrice' => String.valueOf(entry.UnitPrice),
            'RLM_HVAC_Site__c' => siteId,
            'Description' => description.abbreviate(255)
        };
        return qli;
    }

    public static Boolean isProject(Id quoteId) {
        return [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId AND Product2.StockKeepingUnit = :REPLACEMENT_SKU] > 0;
    }

    // ---------------------------------------------------------------- booking and progress

    @AuraEnabled
    public static Status status(Id quoteId) {
        try {
            return statusFor(quoteId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Orders the project with the customer's PO, activates it and releases the deposit. */
    @AuraEnabled
    public static Status book(Id quoteId, String poNumber) {
        try {
            return bookFor(quoteId, poNumber);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static Status bookFor(Id quoteId, String poNumber) {
        Status s = statusFor(quoteId);
        if (!s.isProject) {
            throw new ProjectException('Book Project is for capital project quotes.');
        }
        String po = String.isBlank(poNumber) ? s.poNumber : poNumber.trim();
        if (String.isBlank(po)) {
            throw new ProjectException('Enter the customer\'s PO number.');
        }
        if (po != s.poNumber) {
            update new Quote(Id = quoteId, RLM_HVAC_PO_Number__c = po);
        }
        if (s.orderId == null) {
            Invocable.Action action = Invocable.Action.createStandardAction('createOrdersFromQuote');
            action.setInvocationParameter('quoteId', String.valueOf(quoteId));
            Invocable.Action.Result result = action.invoke()[0];
            if (!result.isSuccess()) {
                throw new ProjectException('Could not create the order: ' + result.getErrors()[0].getMessage());
            }
        }
        RLM_HVAC_ContractOrder.Status booked = RLM_HVAC_ContractOrder.statusFor(quoteId, true);
        if (booked.orderStatus == 'Activated' && booked.orderId != null) {
            releaseDeposit(booked.orderId);
        }
        return statusFor(quoteId);
    }

    /** The deposit milestone appears once billing has set up the order's schedules, so this waits for it. */
    public static void releaseDeposit(Id orderId) {
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs() && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new DepositJob(orderId, 1), Test.isRunningTest() ? 0 : DEPOSIT_DELAY_MINUTES);
        }
    }

    public class DepositJob implements Queueable {
        private final Id orderId;
        private final Integer attempt;

        public DepositJob(Id orderId, Integer attempt) {
            this.orderId = orderId;
            this.attempt = attempt;
        }

        public void execute(QueueableContext context) {
            Map<Id, Set<String>> wanted = new Map<Id, Set<String>>{ orderId => new Set<String>{ DEPOSIT } };
            if (!accomplish(wanted).isEmpty()) {
                RLM_FSL_InvoiceOrder.enqueue(new Set<Id>{ orderId }, Date.today());
            } else if (attempt < DEPOSIT_ATTEMPTS && !Test.isRunningTest()) {
                System.enqueueJob(new DepositJob(orderId, attempt + 1), DEPOSIT_DELAY_MINUTES);
            }
        }
    }

    /**
     * Accomplishes the named milestones on each order's billing schedules. Returns the orders that
     * have them (accomplished now or before), so callers can tell billing hasn't caught up yet.
     */
    public static Set<Id> accomplish(Map<Id, Set<String>> milestonesByOrder) {
        Set<String> names = new Set<String>();
        for (Set<String> n : milestonesByOrder.values()) {
            names.addAll(n);
        }
        Map<Id, Id> orderBySchedule = new Map<Id, Id>();
        for (BillingSchedule bs : [
            SELECT Id, ReferenceEntityId FROM BillingSchedule WHERE ReferenceEntityId IN :milestonesByOrder.keySet()
        ]) {
            orderBySchedule.put(bs.Id, bs.ReferenceEntityId);
        }
        Map<Id, Id> orderByPlan = new Map<Id, Id>();
        for (BillingMilestonePlan plan : [
            SELECT Id, ReferenceItemId FROM BillingMilestonePlan WHERE ReferenceItemId IN :orderBySchedule.keySet()
        ]) {
            orderByPlan.put(plan.Id, orderBySchedule.get(plan.ReferenceItemId));
        }
        Set<Id> found = new Set<Id>();
        List<BillingMilestonePlanItem> open = new List<BillingMilestonePlanItem>();
        for (BillingMilestonePlanItem item : [
            SELECT Id, Name, BillingMilestonePlanId, IsMilestoneAccomplished FROM BillingMilestonePlanItem
            WHERE BillingMilestonePlanId IN :orderByPlan.keySet() AND Name IN :names
        ]) {
            Id orderId = orderByPlan.get(item.BillingMilestonePlanId);
            if (!milestonesByOrder.get(orderId).contains(item.Name)) {
                continue;
            }
            found.add(orderId);
            if (item.IsMilestoneAccomplished != true) {
                open.add(new BillingMilestonePlanItem(Id = item.Id, IsMilestoneAccomplished = true));
            }
        }
        update open;
        return found;
    }

    public static Status statusFor(Id quoteId) {
        Quote q = [
            SELECT Id, Name, Status, RLM_HVAC_PO_Number__c,
                (SELECT Product2.StockKeepingUnit, Quantity, TotalPrice, RLM_HVAC_Site__r.Name FROM QuoteLineItems)
            FROM Quote WHERE Id = :quoteId
        ];
        Status s = new Status();
        s.quoteId = q.Id;
        s.quoteName = q.Name;
        s.quoteStatus = q.Status;
        s.poNumber = q.RLM_HVAC_PO_Number__c;
        for (QuoteLineItem line : q.QuoteLineItems) {
            s.total += line.TotalPrice ?? 0;
            if (line.Product2.StockKeepingUnit == REPLACEMENT_SKU) {
                s.isProject = true;
                s.unitCount = line.Quantity.intValue();
                s.siteName = line.RLM_HVAC_Site__r?.Name;
            }
        }
        Map<String, Milestone> milestoneByName = new Map<String, Milestone>();
        for (String name : MILESTONES.keySet()) {
            Milestone m = new Milestone();
            m.name = name;
            m.percent = MILESTONES.get(name);
            m.amount = (s.total * m.percent / 100).setScale(2, System.RoundingMode.HALF_UP);
            milestoneByName.put(name, m);
            s.milestones.add(m);
        }
        Map<String, Step> steps = new Map<String, Step>();
        for (String stage : STAGES.keySet()) {
            Step st = new Step();
            st.key = stage;
            st.label = STAGES.get(stage)[2];
            steps.put(STAGES.get(stage)[0], st);
            s.steps.add(st);
        }
        List<Order> orders = [SELECT Id, OrderNumber, Status FROM Order WHERE QuoteId = :quoteId ORDER BY CreatedDate DESC LIMIT 1];
        if (orders.isEmpty()) {
            return s;
        }
        Order o = orders[0];
        s.orderId = o.Id;
        s.orderNumber = o.OrderNumber;
        s.orderStatus = o.Status;

        Set<Id> scheduleIds = new Map<Id, BillingSchedule>([SELECT Id FROM BillingSchedule WHERE ReferenceEntityId = :o.Id]).keySet();
        Map<String, Boolean> open = new Map<String, Boolean>();
        for (BillingMilestonePlanItem item : [
            SELECT Name, IsMilestoneAccomplished FROM BillingMilestonePlanItem
            WHERE BillingMilestonePlanId IN (SELECT Id FROM BillingMilestonePlan WHERE ReferenceItemId IN :scheduleIds)
        ]) {
            Boolean pending = item.IsMilestoneAccomplished != true;
            open.put(item.Name, (open.get(item.Name) ?? false) || pending);
        }
        for (String name : open.keySet()) {
            if (milestoneByName.containsKey(name)) {
                milestoneByName.get(name).accomplished = !open.get(name);
            }
        }

        Map<Id, WorkOrder> workOrders = new Map<Id, WorkOrder>([
            SELECT Id, WorkOrderNumber, Status, LineItemCount, RLM_Fulfillment_Step__r.Name FROM WorkOrder
            WHERE RLM_Order__c = :o.Id AND RLM_Fulfillment_Step__c != null
        ]);
        Map<Id, Datetime> starts = new Map<Id, Datetime>();
        for (ServiceAppointment sa : [
            SELECT ParentRecordId, SchedStartTime, EarliestStartTime FROM ServiceAppointment
            WHERE ParentRecordId IN :workOrders.keySet() ORDER BY CreatedDate
        ]) {
            if (!starts.containsKey(sa.ParentRecordId)) {
                starts.put(sa.ParentRecordId, sa.SchedStartTime);
            }
        }
        for (WorkOrder wo : workOrders.values()) {
            Step st = steps.get(wo.RLM_Fulfillment_Step__r.Name);
            if (st == null) {
                continue;
            }
            st.workOrderId = wo.Id;
            st.workOrderNumber = wo.WorkOrderNumber;
            st.workOrderStatus = wo.Status;
            st.lines = wo.LineItemCount ?? 0;
            st.scheduledStart = starts.get(wo.Id);
            st.done = wo.Status == 'Completed';
        }

        Map<Id, InvoiceRef> invoices = new Map<Id, InvoiceRef>();
        for (InvoiceLine line : [
            SELECT InvoiceId, Invoice.DocumentNumber, Invoice.InvoiceDate, Invoice.TotalAmount, Invoice.TotalAmountWithTax
            FROM InvoiceLine WHERE BillingScheduleId IN :scheduleIds
            ORDER BY Invoice.CreatedDate
        ]) {
            if (invoices.containsKey(line.InvoiceId)) {
                continue;
            }
            InvoiceRef ref = new InvoiceRef();
            ref.invoiceId = line.InvoiceId;
            ref.documentNumber = line.Invoice.DocumentNumber;
            ref.invoiceDate = line.Invoice.InvoiceDate;
            ref.charge = line.Invoice.TotalAmount ?? 0;
            ref.total = line.Invoice.TotalAmountWithTax ?? ref.charge;
            invoices.put(line.InvoiceId, ref);
            s.invoiced += ref.charge;
        }
        s.invoices = invoices.values();
        return s;
    }

    // ---------------------------------------------------------------- DRO step work orders

    public class StepRequest {
        @InvocableVariable(required=true label='Fulfillment Order Line Id') public String recordId;
        @InvocableVariable(required=true label='Stage' description='Crane Lift, Install or Commissioning') public String stage;
    }

    public class StepResult {
        @InvocableVariable(label='Work Order Id') public Id workOrderId;
    }

    @InvocableMethod(label='Create Capital Project Work Order' category='Brightline'
        description='DRO AutoTask: creates the crane lift, install or commissioning work order at the project site, linked to the step it completes.')
    public static List<StepResult> createStepWorkOrders(List<StepRequest> requests) {
        List<StepResult> results = new List<StepResult>();
        for (StepRequest r : requests) {
            StepResult result = new StepResult();
            result.workOrderId = createStepWorkOrder(r.recordId, r.stage);
            results.add(result);
        }
        return results;
    }

    /** The work order for one stage of the project; returns the existing one when DRO retries. */
    public static Id createStepWorkOrder(Id fulfillmentLineId, String stage) {
        List<String> cfg = STAGES.get(stage);
        if (cfg == null) {
            throw new ProjectException('Unknown capital project stage: ' + stage);
        }
        FulfillmentStepSource source = [SELECT StepId FROM FulfillmentStepSource WHERE SourceLineItemId = :fulfillmentLineId LIMIT 1];
        FulfillmentStep running = [SELECT FulfillmentPlanId FROM FulfillmentStep WHERE Id = :source.StepId];
        FulfillmentPlan plan = [SELECT SourceIdentifier FROM FulfillmentPlan WHERE Id = :running.FulfillmentPlanId];
        FulfillmentStep completes = [
            SELECT Id FROM FulfillmentStep WHERE FulfillmentPlanId = :plan.Id AND Name = :cfg[0] LIMIT 1
        ];
        for (WorkOrder existing : [SELECT Id FROM WorkOrder WHERE RLM_Fulfillment_Step__c = :completes.Id LIMIT 1]) {
            return existing.Id;
        }
        Id orderId = (Id) plan.SourceIdentifier;
        OrderItem item = [
            SELECT RLM_HVAC_Site__c, Description, Quantity, Order.OrderNumber, Order.PoNumber, Order.ShipToContactId
            FROM OrderItem WHERE OrderId = :orderId AND Product2.StockKeepingUnit = :REPLACEMENT_SKU LIMIT 1
        ];
        Account site = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry
            FROM Account WHERE Id = :item.RLM_HVAC_Site__c
        ];
        List<String> tags = tagsOf(item.Description);
        List<Asset> units = [
            SELECT Id, RLM_HVAC_Unit_Tag__c, RLM_HVAC_Tonnage__c, RLM_HVAC_Install_Year__c, RLM_HVAC_Refrigerant_Type__c
            FROM Asset WHERE AccountId = :site.Id AND RLM_HVAC_Unit_Tag__c IN :tags AND Status != 'Obsolete'
            ORDER BY RLM_HVAC_Unit_Tag__c
        ];
        Id locationId;
        for (AssociatedLocation al : [SELECT LocationId FROM AssociatedLocation WHERE ParentRecordId = :site.Id ORDER BY CreatedDate LIMIT 1]) {
            locationId = al.LocationId;
        }
        Id workTypeId;
        for (WorkType wt : [SELECT Id FROM WorkType WHERE Name = :cfg[1] LIMIT 1]) {
            workTypeId = wt.Id;
        }
        Id territoryId;
        for (ServiceTerritory t : [SELECT Id FROM ServiceTerritory WHERE Name = :RLM_HVAC_CommercialCoverage.TERRITORY LIMIT 1]) {
            territoryId = t.Id;
        }
        String unitText = units.size() + ' rooftop units (' + String.join(tags, ', ') + ')';
        WorkOrder wo = new WorkOrder(
            AccountId = site.Id,
            LocationId = locationId,
            WorkTypeId = workTypeId,
            ServiceTerritoryId = territoryId,
            ContactId = item.Order.ShipToContactId,
            Street = site.BillingStreet,
            City = site.BillingCity,
            State = site.BillingState,
            PostalCode = site.BillingPostalCode,
            Country = site.BillingCountry,
            Status = 'New',
            Priority = 'Medium',
            Subject = (cfg[2] + ': ' + site.Name).left(255),
            Description = descriptionFor(stage, unitText, item.Order.OrderNumber, item.Order.PoNumber),
            RLM_Order__c = orderId,
            RLM_Fulfillment_Step__c = completes.Id
        );
        insert wo;
        if (stage != 'Crane Lift') {
            List<WorkOrderLineItem> lines = new List<WorkOrderLineItem>();
            for (Asset u : units) {
                lines.add(new WorkOrderLineItem(WorkOrderId = wo.Id, AssetId = u.Id, WorkTypeId = workTypeId,
                    Description = (stage == 'Install'
                        ? 'Replace ' + u.RLM_HVAC_Unit_Tag__c + ' (' + u.RLM_HVAC_Tonnage__c.stripTrailingZeros().toPlainString()
                            + ' tons, ' + u.RLM_HVAC_Refrigerant_Type__c + ', ' + u.RLM_HVAC_Install_Year__c + ') with a new '
                            + NEW_REFRIGERANT + ' unit'
                        : 'Start up ' + u.RLM_HVAC_Unit_Tag__c + ': readings, airflow, controls').abbreviate(255)));
            }
            insert lines;
        }
        return wo.Id;
    }

    private static String descriptionFor(String stage, String unitText, String orderNumber, String poNumber) {
        String ref = ' Order ' + orderNumber + (String.isBlank(poNumber) ? '' : ', PO ' + poNumber) + '.';
        if (stage == 'Crane Lift') {
            return ('Crane and rigging: lift the new units onto the roof and the old units off for ' + unitText + '.' + ref).abbreviate(32000);
        }
        if (stage == 'Install') {
            return ('Replace ' + unitText + '. Recover the refrigerant from the old units. Completing this bills the install milestone (40%).' + ref).abbreviate(32000);
        }
        return ('Commission ' + unitText + ' and hand over to the facility. Completing this bills the final 20%.' + ref).abbreviate(32000);
    }

    @TestVisible
    private static List<String> tagsOf(String description) {
        List<String> tags = new List<String>();
        for (String t : (description ?? '').split(',')) {
            if (String.isNotBlank(t)) {
                tags.add(t.trim());
            }
        }
        return tags;
    }

    // ---------------------------------------------------------------- work order completion

    /**
     * After update on Work Order: an install or commissioning work order that completes accomplishes
     * its milestone, and a completed install updates the replaced units.
     */
    public static void workOrdersUpdated(List<WorkOrder> records, Map<Id, WorkOrder> oldMap) {
        Map<Id, WorkOrder> completed = new Map<Id, WorkOrder>();
        Set<Id> stepIds = new Set<Id>();
        for (WorkOrder wo : records) {
            if (wo.Status == 'Completed' && oldMap.get(wo.Id).Status != 'Completed'
                    && wo.RLM_Fulfillment_Step__c != null && wo.RLM_Order__c != null) {
                completed.put(wo.Id, wo);
                stepIds.add(wo.RLM_Fulfillment_Step__c);
            }
        }
        if (completed.isEmpty()) {
            return;
        }
        Map<Id, FulfillmentStep> steps = new Map<Id, FulfillmentStep>([
            SELECT Id, Name FROM FulfillmentStep WHERE Id IN :stepIds AND Name IN (:INSTALL_DONE, :COMMISSIONING_DONE)
        ]);
        if (steps.isEmpty()) {
            return;
        }
        Map<Id, Set<String>> milestonesByOrder = new Map<Id, Set<String>>();
        Set<Id> installs = new Set<Id>();
        for (WorkOrder wo : completed.values()) {
            FulfillmentStep st = steps.get(wo.RLM_Fulfillment_Step__c);
            if (st == null) {
                continue;
            }
            if (!milestonesByOrder.containsKey(wo.RLM_Order__c)) {
                milestonesByOrder.put(wo.RLM_Order__c, new Set<String>());
            }
            milestonesByOrder.get(wo.RLM_Order__c).add(st.Name);
            if (st.Name == INSTALL_DONE) {
                installs.add(wo.Id);
            }
        }
        Set<Id> billed = accomplish(milestonesByOrder);
        replaceUnits(installs);
        if (!billed.isEmpty() && !Test.isRunningTest()) {
            RLM_FSL_InvoiceOrder.enqueue(billed, Date.today());
        }
    }

    /** The install work order's lines name the replaced units; each becomes the new unit in place. */
    private static void replaceUnits(Set<Id> installIds) {
        if (installIds.isEmpty()) {
            return;
        }
        Integer year = Date.today().year();
        Map<Id, Asset> updates = new Map<Id, Asset>();
        for (WorkOrderLineItem line : [
            SELECT AssetId, WorkOrder.WorkOrderNumber, Asset.RLM_HVAC_Install_Year__c, Asset.RLM_HVAC_Refrigerant_Type__c,
                Asset.RLM_HVAC_Refrigerant_Charge__c
            FROM WorkOrderLineItem WHERE WorkOrderId IN :installIds AND AssetId != null
        ]) {
            if (line.Asset.RLM_HVAC_Install_Year__c == year && line.Asset.RLM_HVAC_Refrigerant_Type__c == NEW_REFRIGERANT) {
                continue;
            }
            updates.put(line.AssetId, new Asset(
                Id = line.AssetId,
                RLM_HVAC_Install_Year__c = year,
                RLM_HVAC_Refrigerant_Type__c = NEW_REFRIGERANT,
                InstallDate = Date.today(),
                Status = 'Installed',
                Description = ('Replaced ' + Date.today().format() + ' on work order ' + line.WorkOrder.WorkOrderNumber
                    + '; the previous unit was installed in ' + line.Asset.RLM_HVAC_Install_Year__c + ' with '
                    + line.Asset.RLM_HVAC_Refrigerant_Charge__c + ' lb of ' + line.Asset.RLM_HVAC_Refrigerant_Type__c + '.').abbreviate(32000)
            ));
        }
        update updates.values();
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class ProjectException extends Exception {}
}
