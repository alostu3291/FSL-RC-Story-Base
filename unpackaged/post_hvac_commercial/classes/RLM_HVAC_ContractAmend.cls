/**
 * Adds a site to a property group's Brightline Commercial contract mid-term. The site's rooftop
 * units are priced like the contract (maintenance by tonnage band, filters, the site's response
 * coverage, at the contract's discount) and added on an amendment order that is co-terminated with
 * the contract: lines run from the effective date to the contract's end date, so the first bill is
 * prorated. initiateAmendment anchors the order on an existing contract asset (quantity change 0)
 * and Place Sales Transaction adds the site's lines. Activating it assetizes the lines, and
 * RLM_HVAC_CommercialCoverage gives the new site its entitlement and maintenance plan. The site's
 * lines bill on the group's next consolidated invoice (RLM_HVAC_ContractInvoice.invoiceGroup).
 */
public with sharing class RLM_HVAC_ContractAmend {
    public static final String ORDER_NAME_PREFIX = 'Add site';

    public class Candidate {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public RLM_HVAC_ContractQuote.Site site;
    }

    public class State {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String groupName;
        @AuraEnabled public Boolean hasContract = false;
        @AuraEnabled public Date contractStart;
        @AuraEnabled public Date contractEnd;
        @AuraEnabled public Date effectiveDate;
        @AuraEnabled public Decimal discountPercent = 0;
        @AuraEnabled public Integer coveredSites = 0;
        @AuraEnabled public String poNumber;
        @AuraEnabled public List<Candidate> candidates = new List<Candidate>();
    }

    public class Result {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String message;
    }

    /** The group's contract and the sites that could be added; recordId is the group or one of its sites. */
    @AuraEnabled
    public static State state(Id recordId) {
        try {
            return stateFor(recordId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static Result addSite(Id siteId, String effectiveDate) {
        try {
            State s = stateFor(siteId);
            Candidate chosen;
            for (Candidate c : s.candidates) {
                if (c.accountId == siteId) {
                    chosen = c;
                }
            }
            if (!s.hasContract) {
                throw new AmendException(s.groupName + ' has no active contract to add the site to.');
            }
            if (chosen == null) {
                throw new AmendException('This site is already on the contract or has no rooftop units recorded.');
            }
            Date startDate = String.isBlank(effectiveDate) ? s.effectiveDate : Date.valueOf(effectiveDate);
            if (startDate <= s.contractStart || startDate >= s.contractEnd) {
                throw new AmendException('Pick an effective date after ' + s.contractStart.format()
                    + ' and before the contract ends on ' + s.contractEnd.format() + '.');
            }
            Id orderId = placeAmendment(s, chosen.site, startDate);
            activate(orderId, s, chosen.site, startDate);
            Result r = new Result();
            r.orderId = orderId;
            r.orderNumber = [SELECT OrderNumber FROM Order WHERE Id = :orderId].OrderNumber;
            r.message = chosen.name + ' is on the contract from ' + startDate.format() + ' to ' + s.contractEnd.format()
                + ' on order ' + r.orderNumber + '.';
            return r;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static State stateFor(Id recordId) {
        Account record = [SELECT Id, ParentId FROM Account WHERE Id = :recordId];
        Account grp = [SELECT Id, Name FROM Account WHERE Id = :(record.ParentId != null ? record.ParentId : record.Id)];
        State s = new State();
        s.groupId = grp.Id;
        s.groupName = grp.Name;

        Set<Id> covered = new Set<Id>();
        Datetime now = Datetime.now();
        for (Asset a : [
            SELECT RLM_HVAC_Site__c, LifecycleStartDate, LifecycleEndDate FROM Asset
            WHERE AccountId = :grp.Id AND RLM_HVAC_Site__c != null AND Product2.StockKeepingUnit LIKE 'HVAC-COM-%'
                AND LifecycleEndDate >= :now
        ]) {
            covered.add(a.RLM_HVAC_Site__c);
            Date startDate = a.LifecycleStartDate?.dateGmt();
            Date endDate = a.LifecycleEndDate?.dateGmt();
            if (startDate != null && (s.contractStart == null || startDate < s.contractStart)) {
                s.contractStart = startDate;
            }
            if (endDate != null && (s.contractEnd == null || endDate > s.contractEnd)) {
                s.contractEnd = endDate;
            }
        }
        s.hasContract = !covered.isEmpty() && s.contractStart != null && s.contractEnd != null;
        s.coveredSites = covered.size();
        if (!s.hasContract) {
            return s;
        }
        s.effectiveDate = defaultEffectiveDate(Date.today(), s.contractStart);

        // The PO is this term's (a renewal's, once renewed); the discount is the one the contract was sold at,
        // because renewal quotes carry it in their prices rather than as a line discount.
        for (Quote q : [
            SELECT RLM_HVAC_PO_Number__c FROM Quote
            WHERE QuoteAccountId = :grp.Id AND RLM_Line_of_Business__c = :RLM_HVAC_CommercialPricing.LOB AND Status = 'Accepted'
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            s.poNumber = q.RLM_HVAC_PO_Number__c;
        }
        for (Quote q : [
            SELECT (SELECT Discount FROM QuoteLineItems WHERE Discount > 0 ORDER BY Discount DESC LIMIT 1)
            FROM Quote
            WHERE QuoteAccountId = :grp.Id AND RLM_Line_of_Business__c = :RLM_HVAC_CommercialPricing.LOB AND Status = 'Accepted'
                AND Id IN (SELECT QuoteId FROM QuoteLineItem WHERE Discount > 0)
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            s.discountPercent = q.QuoteLineItems[0].Discount;
        }

        List<Account> open = [
            SELECT Id, Name, RLM_HVAC_Site_Type__c, RLM_HVAC_Response_Tier__c FROM Account
            WHERE ParentId = :grp.Id AND Id NOT IN :covered
            ORDER BY RLM_HVAC_Site_Code__c NULLS LAST, Name
        ];
        if (open.isEmpty()) {
            return s;
        }
        RLM_HVAC_ContractQuote.Plan plan = RLM_HVAC_ContractQuote.planForSites(open, true, s.discountPercent);
        for (RLM_HVAC_ContractQuote.Site site : plan.sites) {
            Candidate c = new Candidate();
            c.accountId = site.accountId;
            c.name = site.name;
            c.site = site;
            s.candidates.add(c);
        }
        return s;
    }

    /** The first of next month, or a month into the contract when it hasn't started yet. */
    @TestVisible
    private static Date defaultEffectiveDate(Date today, Date contractStart) {
        Date next = today.toStartOfMonth().addMonths(1);
        return next > contractStart ? next : contractStart.addMonths(1);
    }

    private static Id placeAmendment(State s, RLM_HVAC_ContractQuote.Site site, Date startDate) {
        Asset anchor = [
            SELECT Id FROM Asset
            WHERE AccountId = :s.groupId AND RLM_HVAC_Site__c != null AND Product2.StockKeepingUnit LIKE 'HVAC-COM-%'
                AND LifecycleEndDate >= :Datetime.now()
            ORDER BY CreatedDate LIMIT 1
        ];
        Invocable.Action amend = Invocable.Action.createStandardAction('initiateAmendment');
        amend.setInvocationParameter('amendAssetIds', new List<String>{ String.valueOf(anchor.Id) });
        amend.setInvocationParameter('amendStartDate',
            Datetime.newInstanceGmt(startDate.year(), startDate.month(), startDate.day()).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss'));
        amend.setInvocationParameter('quantityChange', 0);
        amend.setInvocationParameter('amendOutputType', 'Order');
        Invocable.Action.Result result = amend.invoke()[0];
        if (!result.isSuccess()) {
            throw new AmendException('Amendment failed: ' + result.getErrors()[0].getMessage());
        }
        Id orderId = (Id) result.getOutputParameters().get('amendRecordId');

        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry e : [
            SELECT Id, Product2Id, Product2.StockKeepingUnit FROM PricebookEntry
            WHERE Product2.StockKeepingUnit LIKE 'HVAC-COM-%' AND Pricebook2.IsStandard = true
                AND CurrencyIsoCode = 'USD' AND IsActive = true
        ]) {
            entries.put(e.Product2.StockKeepingUnit, e);
        }
        RevSalesTrxn.RecordResource orderRecord = new RevSalesTrxn.RecordResource(Order.SObjectType, 'PATCH', orderId);
        orderRecord.fieldValues = new Map<String, Object>();
        RevSalesTrxn.RecordResource addAction = new RevSalesTrxn.RecordResource(OrderAction.SObjectType, 'POST');
        addAction.fieldValues = new Map<String, Object>{ 'OrderId' => orderId, 'Type' => 'Add' };
        List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
            new RevSalesTrxn.RecordWithReferenceRequest('refOrder', orderRecord),
            new RevSalesTrxn.RecordWithReferenceRequest('refAdd', addAction)
        };
        Integer n = 0;
        for (RLM_HVAC_ContractQuote.Line line : site.lines) {
            n++;
            PricebookEntry entry = entries.get(line.sku);
            RevSalesTrxn.RecordResource item = new RevSalesTrxn.RecordResource(OrderItem.SObjectType, 'POST');
            item.fieldValues = new Map<String, Object>{
                'OrderId' => orderId, 'OrderActionId' => '@{refAdd.id}',
                'Product2Id' => entry.Product2Id, 'PricebookEntryId' => entry.Id,
                'Quantity' => String.valueOf(line.quantity), 'UnitPrice' => String.valueOf(line.unitPrice),
                'ServiceDate' => String.valueOf(startDate), 'EndDate' => String.valueOf(s.contractEnd),
                'PeriodBoundary' => 'Anniversary', 'BillingFrequency2' => 'Monthly',
                'RLM_HVAC_Site__c' => site.accountId,
                'Description' => (line.units == null ? site.name : line.units).abbreviate(255)
            };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refItem' + n, item));
        }
        RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
            new RevSalesTrxn.GraphRequest('hvacAddSite', records),
            RevSalesTrxn.PricingPreferenceEnum.SYSTEM, RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput(), null, null, RevSalesTrxn.TaxPreferenceEnum.SKIP, null);
        if (response.isSuccess != true) {
            throw new AmendException('Place Sales Transaction failed: ' + JSON.serialize(response.errorResponse));
        }
        return orderId;
    }

    private static void activate(Id orderId, State s, RLM_HVAC_ContractQuote.Site site, Date startDate) {
        Account grp = [
            SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                (SELECT Id, Title FROM Contacts ORDER BY CreatedDate)
            FROM Account WHERE Id = :s.groupId
        ];
        Id payables;
        Id facilities;
        for (Contact c : grp.Contacts) {
            if (payables == null && c.Title != null && c.Title.containsIgnoreCase('Payable')) {
                payables = c.Id;
            }
            if (facilities == null && c.Title != null && c.Title.containsIgnoreCase('Facilit')) {
                facilities = c.Id;
            }
        }
        Order o = new Order(Id = orderId,
            Name = (ORDER_NAME_PREFIX + ': ' + site.name).left(80),
            Description = site.unitCount + ' rooftop units added from ' + startDate.format() + ', co-terminated '
                + s.contractEnd.format() + '.',
            PoNumber = s.poNumber,
            BillingStreet = grp.BillingStreet, BillingCity = grp.BillingCity, BillingState = grp.BillingState,
            BillingPostalCode = grp.BillingPostalCode, BillingCountry = grp.BillingCountry,
            ShippingStreet = grp.BillingStreet, ShippingCity = grp.BillingCity, ShippingState = grp.BillingState,
            ShippingPostalCode = grp.BillingPostalCode, ShippingCountry = grp.BillingCountry,
            BillToContactId = payables ?? facilities,
            ShipToContactId = facilities ?? payables);
        update o;
        if ([SELECT COUNT() FROM AppUsageAssignment WHERE RecordId = :orderId] == 0) {
            insert new AppUsageAssignment(RecordId = orderId, AppUsageType = 'RevenueLifecycleManagement');
        }
        update new Order(Id = orderId, Status = 'Activated');
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class AmendException extends Exception {}
}
