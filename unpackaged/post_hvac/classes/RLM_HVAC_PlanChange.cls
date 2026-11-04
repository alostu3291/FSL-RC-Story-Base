/**
 * Agreement changes from the field: the technician moves the customer to another comfort agreement
 * tier, or adds or removes Indoor Air Quality or Water Heater Care, and the customer approves the
 * change on the device.
 *
 * Changes amend the customer's existing assets. initiateAmendment creates the amendment order
 * for the asset being changed (quantity -1 to end it, 0 to anchor an add), and Place Sales
 * Transaction adds the new plan line. Tier changes carry the UpgradeFrom/UpgradeTo or
 * DowngradeFrom/DowngradeTo subtypes, so assetization records them as upgrades or downgrades.
 * The order is activated and its first bill invoiced. Changes start tomorrow: an amendment that
 * starts on an asset's start date fails assetization. New plans are priced at list price times
 * the customer's service zone multiplier, the same as the field quote. A tier is priced per system and
 * keeps the customer's system count, and a new tier also carries the equipment age adjustment the
 * customer pays on their current tier.
 */
public with sharing class RLM_HVAC_PlanChange {
    public static final String PLANS_CATEGORY = 'PC-HVAC-PLANS';
    public static final String ADD_ON_PLANS_CATEGORY = 'PC-HVAC-ADDONS';
    public static final String BASIC = 'HVAC-BASIC';
    public static final String PLUS = 'HVAC-PLUS';
    public static final String PREMIER = 'HVAC-PREMIER';
    public static final String WATER_HEATER = 'HVAC-WATER-HEATER';
    public static final String IAQ = 'HVAC-IAQ';
    public static final String ORDER_NAME_PREFIX = 'Agreement change';

    /** Product SKUs are unique org-wide, so tests use suffixed SKUs that can't collide with the catalog. */
    @TestVisible
    private static String skuSuffix = '';

    public class Plan {
        @AuraEnabled public String sku;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal price;
        /** Zone list price; for a tier, price is this plus the equipment age adjustment, per system. */
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal adjustment = 0;
        @AuraEnabled public Boolean current = false;
        @AuraEnabled public Boolean recommended = false;
        @AuraEnabled public String reason;
        /** Upgrade, Downgrade, Add or Remove: what choosing this plan does. */
        @AuraEnabled public String change;
        @AuraEnabled public Decimal monthlyChange;
    }

    public class Scheduled {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String summary;
        @AuraEnabled public Date startDate;
        @AuraEnabled public String approvedBy;
    }

    public class State {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String customerName;
        @AuraEnabled public String zoneLabel;
        @AuraEnabled public String currentPlanName;
        @AuraEnabled public Decimal monthlyTotal = 0;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Boolean hasPlans = false;
        /** Systems on the agreement; tiers are priced per system. */
        @AuraEnabled public Integer systemCount = 1;
        @AuraEnabled public String lockedReason;
        /** Equipment age adjustment in the current tier's per-system price, carried to any new tier. */
        @AuraEnabled public Decimal adjustment = 0;
        /** What the adjustment is for, from the system check that priced the agreement; null when unknown. */
        @AuraEnabled public String adjustmentReasons;
        @AuraEnabled public List<Plan> tiers = new List<Plan>();
        @AuraEnabled public List<Plan> addOnPlans = new List<Plan>();
        @AuraEnabled public List<Scheduled> scheduled = new List<Scheduled>();
    }

    /** One amendment: the asset it amends, how its quantity changes, and the plan line it adds. */
    public class Change {
        public Id accountId;
        public Id assetId;
        public Integer quantityChange;
        public Date startDate;
        public String fromSubtype;
        public String toSubtype;
        public PricebookEntry entry;
        public Decimal unitPrice;
        public Integer quantity = 1;
    }

    public interface ChangePlacer {
        Id place(Change change);
    }

    @TestVisible
    private static ChangePlacer placer = new AmendmentPlacer();

    @AuraEnabled
    public static State getState(Id recordId) {
        try {
            return buildState(contextFor(recordId));
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Plans the finding notes call for beyond the fixed rules, from RLM_HVAC_AI. Empty when AI is unavailable. */
    @AuraEnabled
    public static List<RLM_HVAC_AI.Pick> aiSuggestions(Id recordId) {
        try {
            State state = buildState(contextFor(recordId));
            List<RLM_HVAC_AI.Option> options = new List<RLM_HVAC_AI.Option>();
            List<Plan> plans = new List<Plan>(state.tiers);
            plans.addAll(state.addOnPlans);
            for (Plan p : plans) {
                if (p.current != true && p.recommended != true) {
                    options.add(new RLM_HVAC_AI.Option(p.sku, p.name, p.description));
                }
            }
            if (state.lockedReason != null || state.hasPlans != true) {
                return new List<RLM_HVAC_AI.Pick>();
            }
            return RLM_HVAC_AI.suggestProducts(state.accountId, options, 'comfort agreements (a home has one agreement tier, priced per system, plus optional add-ons)');
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Schedules the change to the chosen plan for tomorrow, once the customer has approved it. */
    @AuraEnabled
    public static State applyChange(Id recordId, String sku, String approvedBy) {
        try {
            Context context = contextFor(recordId);
            if (String.isBlank(approvedBy)) {
                throw new PlanChangeException('Enter the name of the customer approving the change.');
            }
            Holdings holdings = holdingsFor(context.account.Id);
            if (holdings.lockedReason != null) {
                throw new PlanChangeException(holdings.lockedReason);
            }
            if (holdings.byAsset.isEmpty()) {
                throw new PlanChangeException('This customer has no active agreement to change.');
            }
            Map<String, PricebookEntry> entries = entriesBySku();
            PricebookEntry entry = entries.get(sku);
            if (entry == null) {
                throw new PlanChangeException('Agreement ' + sku + ' is not available.');
            }
            Decimal multiplier = zoneMultiplier(context);
            Holding tier = holdings.tier();
            Holding existing = holdings.forSku(sku);

            Change change = new Change();
            change.accountId = context.account.Id;
            change.startDate = Date.today().addDays(1);
            String summary;
            if (existing != null && isTier(sku)) {
                throw new PlanChangeException('The customer is already on ' + entry.Product2.Name + '.');
            } else if (existing != null) {
                change.assetId = existing.assetId;
                change.quantityChange = -existing.quantity;
                summary = 'Remove ' + existing.name;
            } else if (isTier(sku) && tier != null) {
                Decimal price = tierPrice(entry, multiplier, tier, entries);
                String direction = price >= tier.price ? 'Upgrade' : 'Downgrade';
                change.assetId = tier.assetId;
                change.quantityChange = -tier.quantity;
                change.quantity = tier.quantity;
                change.fromSubtype = direction + 'From';
                change.toSubtype = direction + 'To';
                change.entry = entry;
                change.unitPrice = price;
                summary = direction + ' ' + tier.name + ' to ' + entry.Product2.Name
                    + (tier.quantity > 1 ? ' (' + tier.quantity + ' systems)' : '');
            } else {
                Holding anchor = tier != null ? tier : holdings.byAsset.values()[0];
                change.assetId = anchor.assetId;
                change.quantityChange = 0;
                change.entry = entry;
                change.unitPrice = RLM_HVAC_ZonePricing.apply(entry.UnitPrice, multiplier);
                summary = 'Add ' + entry.Product2.Name;
            }

            Id orderId = placer.place(change);
            activate(orderId, context, change.startDate, summary, approvedBy.trim());
            return buildState(context);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static void activate(Id orderId, Context context, Date startDate, String summary, String approvedBy) {
        Account a = context.account;
        Order o = new Order(Id = orderId,
            Name = (ORDER_NAME_PREFIX + ': ' + summary).left(80),
            Description = 'Approved by ' + approvedBy + ' on ' + Datetime.now().format('MMM d, yyyy h:mm a')
                + (context.workOrderNumber == null ? '' : ' during work order ' + context.workOrderNumber) + '.',
            ShippingStreet = a.ShippingStreet, ShippingCity = a.ShippingCity, ShippingState = a.ShippingState,
            ShippingPostalCode = a.ShippingPostalCode, ShippingCountry = a.ShippingCountry,
            BillingStreet = a.BillingStreet, BillingCity = a.BillingCity, BillingState = a.BillingState,
            BillingPostalCode = a.BillingPostalCode, BillingCountry = a.BillingCountry);
        if (context.contactId != null) {
            o.BillToContactId = context.contactId;
            o.ShipToContactId = context.contactId;
        }
        update o;
        if ([SELECT COUNT() FROM AppUsageAssignment WHERE RecordId = :orderId] == 0) {
            insert new AppUsageAssignment(RecordId = orderId, AppUsageType = 'RevenueLifecycleManagement');
        }
        update new Order(Id = orderId, Status = 'Activated');
        if (!Test.isRunningTest()) {
            RLM_FSL_InvoiceOrder.enqueue(new Set<Id>{ orderId }, startDate);
        }
    }

    public class AmendmentPlacer implements ChangePlacer {
        public Id place(Change change) {
            Invocable.Action amend = Invocable.Action.createStandardAction('initiateAmendment');
            amend.setInvocationParameter('amendAssetIds', new List<String>{ String.valueOf(change.assetId) });
            amend.setInvocationParameter('amendStartDate', Datetime.newInstanceGmt(
                change.startDate.year(), change.startDate.month(), change.startDate.day()
            ).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss'));
            amend.setInvocationParameter('quantityChange', change.quantityChange);
            amend.setInvocationParameter('amendOutputType', 'Order');
            Invocable.Action.Result result = amend.invoke()[0];
            if (!result.isSuccess()) {
                throw new PlanChangeException('Amendment failed: ' + result.getErrors()[0].getMessage());
            }
            Id orderId = (Id) result.getOutputParameters().get('amendRecordId');
            if (change.entry == null && change.fromSubtype == null) {
                return orderId;
            }

            RevSalesTrxn.RecordResource orderRecord = new RevSalesTrxn.RecordResource(Order.SObjectType, 'PATCH', orderId);
            orderRecord.fieldValues = new Map<String, Object>();
            List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{
                new RevSalesTrxn.RecordWithReferenceRequest('refOrder', orderRecord)
            };
            if (change.fromSubtype != null) {
                OrderAction fromAction = [SELECT Id FROM OrderAction WHERE OrderId = :orderId LIMIT 1];
                RevSalesTrxn.RecordResource fromRecord =
                    new RevSalesTrxn.RecordResource(OrderAction.SObjectType, 'PATCH', fromAction.Id);
                fromRecord.fieldValues = new Map<String, Object>{ 'Subtype' => change.fromSubtype };
                records.add(new RevSalesTrxn.RecordWithReferenceRequest('refFrom', fromRecord));
            }
            if (change.entry != null) {
                RevSalesTrxn.RecordResource addAction = new RevSalesTrxn.RecordResource(OrderAction.SObjectType, 'POST');
                addAction.fieldValues = new Map<String, Object>{ 'OrderId' => orderId, 'Type' => 'Add' };
                if (change.toSubtype != null) {
                    addAction.fieldValues.put('Subtype', change.toSubtype);
                }
                RevSalesTrxn.RecordResource item = new RevSalesTrxn.RecordResource(OrderItem.SObjectType, 'POST');
                item.fieldValues = new Map<String, Object>{
                    'OrderId' => orderId, 'OrderActionId' => '@{refAdd.id}',
                    'Product2Id' => change.entry.Product2Id, 'PricebookEntryId' => change.entry.Id,
                    'Quantity' => String.valueOf(change.quantity), 'UnitPrice' => String.valueOf(change.unitPrice),
                    'ServiceDate' => String.valueOf(change.startDate),
                    'PeriodBoundary' => 'Anniversary', 'BillingFrequency2' => 'Monthly'
                };
                records.add(new RevSalesTrxn.RecordWithReferenceRequest('refAdd', addAction));
                records.add(new RevSalesTrxn.RecordWithReferenceRequest('refItem', item));
            }
            RevSalesTrxn.PlaceSalesTransactionResponse response = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                new RevSalesTrxn.GraphRequest('hvacPlanChange', records),
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM, RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                new RevSalesTrxn.ConfigurationOptionsInput(), null, null, RevSalesTrxn.TaxPreferenceEnum.SKIP, null);
            if (response.isSuccess != true) {
                throw new PlanChangeException('Place Sales Transaction failed: ' + JSON.serialize(response.errorResponse));
            }
            return orderId;
        }
    }

    // ---------- holdings ----------

    @TestVisible
    private class Holding {
        Id assetId;
        String sku;
        String name;
        /** Per unit: per system for a tier. */
        Decimal price;
        Integer quantity = 1;
    }

    private class Holdings {
        Map<Id, Holding> byAsset = new Map<Id, Holding>();
        String lockedReason;

        Holding tier() {
            Holding best;
            for (Holding h : byAsset.values()) {
                if (isTier(h.sku) && (best == null || tierRank(h.sku) > tierRank(best.sku))) {
                    best = h;
                }
            }
            return best;
        }

        Holding forSku(String sku) {
            for (Holding h : byAsset.values()) {
                if (h.sku == sku) {
                    return h;
                }
            }
            return null;
        }

        Decimal total() {
            Decimal total = 0;
            for (Holding h : byAsset.values()) {
                total += h.price == null ? 0 : h.price * h.quantity;
            }
            return total;
        }
    }

    /**
     * The customer's plans as they stand once every scheduled change has taken effect, read from the
     * assets' state periods (the latest period of each plan asset). Plans with a change still to come
     * are locked: amending them again before it takes effect would overlap it.
     */
    private static Holdings holdingsFor(Id accountId) {
        Holdings holdings = new Holdings();
        Date today = Date.today();
        Map<Id, AssetStatePeriod> latest = new Map<Id, AssetStatePeriod>();
        Boolean pending = false;
        for (AssetStatePeriod period : [
            SELECT AssetId, Asset.Name, Asset.Product2.Name, Asset.Product2.StockKeepingUnit,
                StartDate, EndDate, Quantity, Mrr
            FROM AssetStatePeriod
            WHERE Asset.AccountId = :accountId
                AND Asset.Product2.StockKeepingUnit IN :catalogSkus()
            ORDER BY StartDate
        ]) {
            latest.put(period.AssetId, period);
            pending |= period.StartDate.date() > today;
        }
        for (AssetStatePeriod period : latest.values()) {
            if (period.Quantity == null || period.Quantity <= 0) {
                continue;
            }
            Holding h = new Holding();
            h.assetId = period.AssetId;
            h.sku = period.Asset.Product2.StockKeepingUnit.removeEnd(skuSuffix);
            h.name = period.Asset.Product2.Name;
            h.price = period.Mrr == null ? null : period.Mrr / period.Quantity;
            h.quantity = Math.max(1, period.Quantity.intValue());
            holdings.byAsset.put(h.assetId, h);
        }
        if (pending || !scheduledFor(accountId).isEmpty()) {
            holdings.lockedReason = 'An agreement change is already scheduled. Make the next change after it takes effect.';
        }
        return holdings;
    }

    private static List<Scheduled> scheduledFor(Id accountId) {
        List<Scheduled> result = new List<Scheduled>();
        String prefix = ORDER_NAME_PREFIX + ': ';
        String namePattern = ORDER_NAME_PREFIX + ':%';
        for (Order o : [
            SELECT Id, OrderNumber, Name, Description, EffectiveDate
            FROM Order
            WHERE AccountId = :accountId AND Name LIKE :namePattern AND EffectiveDate > TODAY
            ORDER BY CreatedDate DESC
        ]) {
            Scheduled s = new Scheduled();
            s.orderId = o.Id;
            s.orderNumber = o.OrderNumber;
            s.summary = o.Name.removeStart(prefix);
            s.startDate = o.EffectiveDate;
            s.approvedBy = o.Description;
            result.add(s);
        }
        return result;
    }

    // ---------- state ----------

    private static State buildState(Context context) {
        State state = new State();
        state.accountId = context.account.Id;
        state.customerName = context.customerName;
        state.startDate = Date.today().addDays(1);
        Decimal multiplier = zoneMultiplier(context);
        if (context.zoneName != null) {
            state.zoneLabel = context.zoneName + ' x' + multiplier.setScale(2);
        }

        Holdings holdings = holdingsFor(context.account.Id);
        state.scheduled = scheduledFor(context.account.Id);
        state.lockedReason = holdings.lockedReason;
        state.hasPlans = !holdings.byAsset.isEmpty();
        state.monthlyTotal = holdings.total();
        Holding tier = holdings.tier();
        state.currentPlanName = tier == null ? null : tier.name;
        state.systemCount = tier == null ? 1 : tier.quantity;

        Map<String, String> reasons = recommend(context.assessmentId, tier == null ? null : tier.sku);
        Map<String, PricebookEntry> entries = entriesBySku();
        state.adjustment = adjustmentOf(tier, entries, multiplier);
        if (state.adjustment > 0) {
            state.adjustmentReasons = adjustmentReasons(context.account.Id, state.adjustment);
        }
        for (String sku : planSkus()) {
            PricebookEntry entry = entries.get(sku);
            if (entry == null) {
                continue;
            }
            Holding held = holdings.forSku(sku);
            Plan p = new Plan();
            p.sku = sku;
            p.name = entry.Product2.Name;
            p.description = entry.Product2.Description;
            p.current = held != null;
            if (held != null && held.price != null) {
                p.price = held.price;
            } else if (isTier(sku)) {
                p.price = tierPrice(entry, multiplier, tier, entries);
            } else {
                p.price = RLM_HVAC_ZonePricing.apply(entry.UnitPrice, multiplier);
            }
            p.listPrice = RLM_HVAC_ZonePricing.apply(entry.UnitPrice, multiplier).setScale(2, RoundingMode.HALF_UP);
            p.adjustment = isTier(sku) && p.price != null ? (p.price - p.listPrice).setScale(2) : 0;
            p.reason = reasons.get(sku);
            p.recommended = p.reason != null && !p.current;
            if (isTier(sku)) {
                if (!p.current) {
                    p.change = tier == null ? 'Add' : (p.price >= tier.price ? 'Upgrade' : 'Downgrade');
                    p.monthlyChange = (p.price - (tier == null || tier.price == null ? 0 : tier.price)) * state.systemCount;
                }
                state.tiers.add(p);
            } else {
                p.change = p.current ? 'Remove' : 'Add';
                p.monthlyChange = p.current ? -p.price : p.price;
                state.addOnPlans.add(p);
            }
        }
        return state;
    }

    /**
     * A tier's per-system price for this customer: list price for their zone plus the equipment age
     * adjustment they pay on their current tier, which Check & Quote adds to the tier only.
     */
    private static Decimal tierPrice(PricebookEntry entry, Decimal multiplier, Holding current, Map<String, PricebookEntry> entries) {
        return (RLM_HVAC_ZonePricing.apply(entry.UnitPrice, multiplier) + adjustmentOf(current, entries, multiplier))
            .setScale(2, RoundingMode.HALF_UP);
    }

    /** The equipment age adjustment in the current tier's per-system price: what it costs above the zone list price. */
    private static Decimal adjustmentOf(Holding current, Map<String, PricebookEntry> entries, Decimal multiplier) {
        PricebookEntry currentEntry = current == null ? null : entries.get(current.sku);
        if (current?.price == null || currentEntry == null) {
            return 0;
        }
        Decimal uplift = current.price - RLM_HVAC_ZonePricing.apply(currentEntry.UnitPrice, multiplier);
        return uplift > 0 ? uplift.setScale(2, RoundingMode.HALF_UP) : 0;
    }

    /**
     * "equipment 11–15 years old +$6" from the system check that priced the agreement, when it accounts
     * for the adjustment. Customers quoted without a system check get no reasons.
     */
    private static String adjustmentReasons(Id accountId, Decimal adjustment) {
        for (RLM_HVAC_Assessment__c assessment : [
            SELECT Equipment_Age__c, Age_Adjustment__c FROM RLM_HVAC_Assessment__c
            WHERE Account__c = :accountId AND Age_Adjustment__c != null
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            if (assessment.Age_Adjustment__c == adjustment) {
                return RLM_HVAC_FieldQuote.adjustmentReasons(assessment.Equipment_Age__c);
            }
        }
        return null;
    }

    /** Which agreements and add-ons the system check's findings call for, given the customer's current tier. */
    @TestVisible
    private static Map<String, String> recommend(Id assessmentId, String currentTier) {
        Map<String, String> result = new Map<String, String>();
        if (assessmentId == null) {
            return result;
        }
        Integer rank = tierRank(currentTier);
        for (RLM_HVAC_Finding__c f : [
            SELECT Equipment__c, Component__c, Condition__c, Urgency__c FROM RLM_HVAC_Finding__c
            WHERE Assessment__c = :assessmentId ORDER BY CreatedDate
        ]) {
            String place = f.Equipment__c == null ? '' : ' on the ' + f.Equipment__c.toLowerCase();
            if (f.Equipment__c == 'Water Heater' || f.Condition__c == 'Sediment') {
                put(result, WATER_HEATER, (f.Condition__c == 'Sediment' ? 'Sediment in the water heater' : 'Water heater' + (f.Condition__c == null ? '' : ' ' + f.Condition__c.toLowerCase())));
            }
            if (f.Equipment__c == 'Indoor Air' || f.Condition__c == 'Allergies Noted'
                    || (f.Component__c == 'Filter' && f.Condition__c == 'Clogged')) {
                put(result, IAQ, f.Condition__c == 'Allergies Noted' ? 'Allergies noted in the home' : 'Clogged filter' + place);
            }
            if (f.Condition__c == 'Aging Equipment' && rank < tierRank(PLUS)) {
                put(result, PLUS, 'Aging equipment' + place + ', which Comfort Plus covers with 8-hour priority response');
            }
            if ((f.Urgency__c == 'Safety' || f.Condition__c == 'Failed') && rank < tierRank(PREMIER)) {
                put(result, PREMIER, (f.Urgency__c == 'Safety' ? 'Safety finding' : 'Failed ' + (f.Component__c == null ? 'part' : f.Component__c.toLowerCase()))
                    + place + ', which Comfort Premier covers with 4-hour response and repair discounts');
            }
        }
        return result;
    }

    private static void put(Map<String, String> result, String sku, String reason) {
        if (!result.containsKey(sku)) {
            result.put(sku, reason);
        }
    }

    private static List<String> planSkus() {
        return new List<String>{ BASIC, PLUS, PREMIER, IAQ, WATER_HEATER };
    }

    private static List<String> catalogSkus() {
        List<String> skus = new List<String>();
        for (String sku : planSkus()) {
            skus.add(sku + skuSuffix);
        }
        return skus;
    }

    private static Boolean isTier(String sku) {
        return tierRank(sku) > 0;
    }

    private static Integer tierRank(String sku) {
        return sku == BASIC ? 1 : sku == PLUS ? 2 : sku == PREMIER ? 3 : 0;
    }

    private static Map<String, PricebookEntry> entriesBySku() {
        Id standardId = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        Map<String, PricebookEntry> entries = new Map<String, PricebookEntry>();
        for (PricebookEntry entry : [
            SELECT Id, UnitPrice, Pricebook2Id, Product2Id, Product2.StockKeepingUnit, Product2.Name, Product2.Description
            FROM PricebookEntry
            WHERE Product2.StockKeepingUnit IN :catalogSkus() AND Pricebook2Id = :standardId
                AND CurrencyIsoCode = 'USD' AND IsActive = true AND Product2.IsActive = true
        ]) {
            entries.put(entry.Product2.StockKeepingUnit.removeEnd(skuSuffix), entry);
        }
        return entries;
    }

    // ---------- context ----------

    private class Context {
        Account account;
        Id contactId;
        String customerName;
        String workOrderNumber;
        Id assessmentId;
        String postalCode;
        String zoneName;
        Decimal multiplier;
    }

    private static Decimal zoneMultiplier(Context context) {
        if (context.multiplier == null) {
            RLM_HVAC_ZonePricing.ZoneResult zone = RLM_HVAC_ZonePricing.resolve(context.postalCode);
            context.multiplier = zone == null || zone.multiplier == null ? 1 : zone.multiplier;
            context.zoneName = zone == null ? null : zone.zoneName;
        }
        return context.multiplier;
    }

    /** Accepts a service appointment, work order or account. */
    private static Context contextFor(Id recordId) {
        if (recordId == null) {
            throw new PlanChangeException('Open this from a service appointment, work order or account.');
        }
        Id targetId = recordId;
        if (recordId.getSobjectType() == ServiceAppointment.SObjectType) {
            targetId = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId].ParentRecordId;
        }
        Context context = new Context();
        Id accountId;
        if (targetId != null && targetId.getSobjectType() == WorkOrder.SObjectType) {
            WorkOrder wo = [
                SELECT WorkOrderNumber, AccountId, ContactId, Contact.Name, PostalCode, RLM_HVAC_Assessment__c
                FROM WorkOrder WHERE Id = :targetId
            ];
            accountId = wo.AccountId;
            context.workOrderNumber = wo.WorkOrderNumber;
            context.contactId = wo.ContactId;
            context.customerName = wo.Contact == null ? null : wo.Contact.Name;
            context.assessmentId = wo.RLM_HVAC_Assessment__c;
            context.postalCode = wo.PostalCode;
        } else if (targetId != null && targetId.getSobjectType() == Account.SObjectType) {
            accountId = targetId;
        }
        if (accountId == null) {
            throw new PlanChangeException('Open this from a service appointment, work order or account.');
        }
        context.account = [
            SELECT Id, Name, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                (SELECT Id, Name FROM Contacts ORDER BY CreatedDate LIMIT 1),
                (SELECT Id FROM HVAC_Assessments__r ORDER BY CreatedDate DESC LIMIT 1)
            FROM Account WHERE Id = :accountId
        ];
        if (context.contactId == null && !context.account.Contacts.isEmpty()) {
            context.contactId = context.account.Contacts[0].Id;
            if (context.customerName == null) {
                context.customerName = context.account.Contacts[0].Name;
            }
        }
        if (context.customerName == null) {
            context.customerName = context.account.Name;
        }
        if (context.assessmentId == null && !context.account.HVAC_Assessments__r.isEmpty()) {
            context.assessmentId = context.account.HVAC_Assessments__r[0].Id;
        }
        if (String.isBlank(context.postalCode)) {
            context.postalCode = context.account.ShippingPostalCode;
        }
        return context;
    }

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    public class PlanChangeException extends Exception {}
}
