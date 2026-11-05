/**
 * Field Service coverage for Brightline Commercial contracts.
 *
 * Activating a contract order assetizes its lines on the property group's account. Asset creation
 * doesn't copy order product fields, so once the asset action sources exist each contract asset takes
 * its site from the order product it came from (AssetActionSource -> OrderItem.RLM_HVAC_Site__c).
 * Each site then gets:
 *  - an Entitlement on the site's response coverage asset, on the site account, running the Brightline
 *    Comfort Response process; RLM_HVAC_Coverage marks the site's service calls Covered from it and
 *    sets the 4-hour or next-business-day priority;
 *  - one Maintenance Plan at the site's Location with a quarterly rule per rooftop unit, so each
 *    generated visit is one Work Order for the site with a line per unit.
 * A renewal extends the contract assets' end dates, which extends the entitlements and plans.
 */
public with sharing class RLM_HVAC_CommercialCoverage {
    public static final String PLAN_TITLE = 'Brightline commercial maintenance';
    public static final String MAINTENANCE_WORK_TYPE = 'Commercial RTU Maintenance';
    public static final String TERRITORY = 'Naperville IL';
    public static final String QUARTERLY_RULE = 'FREQ=MONTHLY;INTERVAL=3';
    private static final String COVERED_SYSTEMS = 'Cooling;Heating';
    private static final String SKU_PREFIX = 'HVAC-COM-%';
    /** Assetization creates the asset before its action source, so the job waits for both. */
    private static final Integer DELAY_MINUTES = 1;
    private static final Integer MAX_ATTEMPTS = 3;

    /** Contract assets were created: find their sites once assetization is done. */
    public static void assetsInserted(List<Asset> assets) {
        Set<Id> productIds = new Set<Id>();
        for (Asset a : assets) {
            if (a.Product2Id != null && a.RLM_HVAC_Site__c == null) {
                productIds.add(a.Product2Id);
            }
        }
        if (productIds.isEmpty()) {
            return;
        }
        Set<Id> contractProducts = new Map<Id, Product2>(
            [SELECT Id FROM Product2 WHERE Id IN :productIds AND StockKeepingUnit LIKE :SKU_PREFIX]
        ).keySet();
        Set<Id> assetIds = new Set<Id>();
        for (Asset a : assets) {
            if (contractProducts.contains(a.Product2Id) && a.RLM_HVAC_Site__c == null) {
                assetIds.add(a.Id);
            }
        }
        if (!assetIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
                && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new SiteJob(assetIds, 1), Test.isRunningTest() ? 0 : DELAY_MINUTES);
        }
    }

    /** A renewal moved contract assets' end dates: extend their sites' entitlements and plans. */
    public static void assetsUpdated(List<Asset> assets, Map<Id, Asset> oldMap) {
        Set<Id> siteIds = new Set<Id>();
        for (Asset a : assets) {
            if (a.RLM_HVAC_Site__c != null && a.LifecycleEndDate != oldMap.get(a.Id).LifecycleEndDate) {
                siteIds.add(a.RLM_HVAC_Site__c);
            }
        }
        if (!siteIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()
                && !(Test.isRunningTest() && System.isQueueable())) {
            System.enqueueJob(new RefreshJob(siteIds), Test.isRunningTest() ? 0 : DELAY_MINUTES);
        }
    }

    public class RefreshJob implements Queueable {
        private final Set<Id> siteIds;

        public RefreshJob(Set<Id> siteIds) {
            this.siteIds = siteIds;
        }

        public void execute(QueueableContext context) {
            RLM_HVAC_Coverage.generate(activate(siteIds));
        }
    }

    public class SiteJob implements Queueable {
        private final Set<Id> assetIds;
        private final Integer attempt;

        public SiteJob(Set<Id> assetIds, Integer attempt) {
            this.assetIds = assetIds;
            this.attempt = attempt;
        }

        public void execute(QueueableContext context) {
            Set<Id> waiting = new Set<Id>();
            Set<Id> siteIds = stampSites(assetIds, waiting);
            if (!waiting.isEmpty() && attempt < MAX_ATTEMPTS && !Test.isRunningTest()) {
                System.enqueueJob(new SiteJob(waiting, attempt + 1), DELAY_MINUTES);
            }
            RLM_HVAC_Coverage.generate(activate(siteIds));
        }
    }

    /**
     * Sets each contract asset's site from its order product. Assets whose action source isn't there
     * yet go into waiting. Returns the sites that gained assets.
     */
    public static Set<Id> stampSites(Set<Id> assetIds, Set<Id> waiting) {
        Map<Id, Id> orderItemByAsset = new Map<Id, Id>();
        for (AssetActionSource source : [
            SELECT AssetAction.AssetId, ReferenceEntityItemId FROM AssetActionSource
            WHERE AssetAction.AssetId IN :assetIds AND ReferenceEntityItemId != null
            ORDER BY CreatedDate
        ]) {
            if (source.ReferenceEntityItemId.getSobjectType() == OrderItem.SObjectType) {
                orderItemByAsset.put(source.AssetAction.AssetId, source.ReferenceEntityItemId);
            }
        }
        Map<Id, OrderItem> orderItems = new Map<Id, OrderItem>(
            [SELECT Id, RLM_HVAC_Site__c FROM OrderItem WHERE Id IN :orderItemByAsset.values()]
        );
        List<Asset> stamped = new List<Asset>();
        Set<Id> siteIds = new Set<Id>();
        for (Id assetId : assetIds) {
            OrderItem item = orderItems.get(orderItemByAsset.get(assetId));
            if (item == null) {
                waiting.add(assetId);
            } else if (item.RLM_HVAC_Site__c != null) {
                stamped.add(new Asset(Id = assetId, RLM_HVAC_Site__c = item.RLM_HVAC_Site__c));
                siteIds.add(item.RLM_HVAC_Site__c);
            }
        }
        update stamped;
        return siteIds;
    }

    private class SiteCoverage {
        Account site;
        Id locationId;
        Asset response;
        Date startDate;
        Date endDate;
        List<Asset> units = new List<Asset>();
    }

    /**
     * Gives each site its response entitlement and its maintenance plan with a quarterly rule per
     * rooftop unit. Runs again safely: existing entitlements, plans and unit rules are kept.
     * Returns the plans that gained unit rules, which need generating.
     */
    public static Set<Id> activate(Set<Id> siteIds) {
        if (siteIds.isEmpty()) {
            return new Set<Id>();
        }
        Map<Id, SiteCoverage> bySite = new Map<Id, SiteCoverage>();
        for (Account site : [
            SELECT Id, Name, RLM_HVAC_Response_Tier__c, BillingStreet, BillingCity, BillingState, BillingPostalCode,
                BillingCountry
            FROM Account WHERE Id IN :siteIds
        ]) {
            SiteCoverage sc = new SiteCoverage();
            sc.site = site;
            bySite.put(site.Id, sc);
        }
        for (AssociatedLocation al : [
            SELECT ParentRecordId, LocationId FROM AssociatedLocation WHERE ParentRecordId IN :siteIds
            ORDER BY CreatedDate
        ]) {
            bySite.get(al.ParentRecordId).locationId = al.LocationId;
        }
        for (Asset a : [
            SELECT Id, Name, RLM_HVAC_Site__c, Product2.StockKeepingUnit, LifecycleStartDate, LifecycleEndDate
            FROM Asset WHERE RLM_HVAC_Site__c IN :siteIds AND Product2.StockKeepingUnit LIKE :SKU_PREFIX
            ORDER BY CreatedDate DESC
        ]) {
            SiteCoverage sc = bySite.get(a.RLM_HVAC_Site__c);
            Date startDate = a.LifecycleStartDate?.dateGmt();
            Date endDate = a.LifecycleEndDate?.dateGmt();
            if (startDate != null && (sc.startDate == null || startDate < sc.startDate)) {
                sc.startDate = startDate;
            }
            if (endDate != null && (sc.endDate == null || endDate > sc.endDate)) {
                sc.endDate = endDate;
            }
            if (sc.response == null && RLM_HVAC_CommercialPricing.isResponse(a.Product2.StockKeepingUnit)) {
                sc.response = a;
            }
        }
        for (Asset unit : [
            SELECT Id, Name, AccountId, RLM_HVAC_Unit_Tag__c FROM Asset
            WHERE AccountId IN :siteIds AND RLM_HVAC_Tonnage__c != null AND Status != 'Obsolete'
            ORDER BY RLM_HVAC_Unit_Tag__c
        ]) {
            bySite.get(unit.AccountId).units.add(unit);
        }
        for (SiteCoverage sc : bySite.values()) {
            if (sc.startDate == null) {
                sc.startDate = Date.today();
            }
        }
        syncEntitlements(bySite.values());
        return syncPlans(bySite.values());
    }

    private static void syncEntitlements(List<SiteCoverage> sites) {
        Set<Id> responseIds = new Set<Id>();
        for (SiteCoverage sc : sites) {
            if (sc.response != null) {
                responseIds.add(sc.response.Id);
            }
        }
        Map<Id, Entitlement> entitled = new Map<Id, Entitlement>();
        for (Entitlement e : [SELECT Id, AssetId, EndDate FROM Entitlement WHERE AssetId IN :responseIds]) {
            entitled.put(e.AssetId, e);
        }
        Id process = responseProcessId();
        List<Entitlement> created = new List<Entitlement>();
        List<Entitlement> extended = new List<Entitlement>();
        for (SiteCoverage sc : sites) {
            if (sc.response == null) {
                continue;
            }
            Entitlement existing = entitled.get(sc.response.Id);
            if (existing != null) {
                if (sc.endDate != null && existing.EndDate != null && existing.EndDate < sc.endDate) {
                    extended.add(new Entitlement(Id = existing.Id, EndDate = sc.endDate));
                }
                continue;
            }
            created.add(new Entitlement(
                Name = (sc.site.Name + ' - ' + sc.site.RLM_HVAC_Response_Tier__c + ' response').abbreviate(255),
                AccountId = sc.site.Id,
                AssetId = sc.response.Id,
                StartDate = sc.startDate,
                EndDate = sc.endDate,
                RLM_HVAC_Covered_Systems__c = COVERED_SYSTEMS,
                SlaProcessId = process
            ));
        }
        insert created;
        update extended;
    }

    private static Set<Id> syncPlans(List<SiteCoverage> sites) {
        Id workTypeId = workTypeId();
        Map<Id, MaintenancePlan> planBySite = new Map<Id, MaintenancePlan>();
        Set<Id> siteIds = new Set<Id>();
        for (SiteCoverage sc : sites) {
            siteIds.add(sc.site.Id);
        }
        for (MaintenancePlan mp : [
            SELECT Id, AccountId, EndDate FROM MaintenancePlan WHERE AccountId IN :siteIds AND MaintenancePlanTitle = :PLAN_TITLE
        ]) {
            planBySite.put(mp.AccountId, mp);
        }
        List<MaintenancePlan> newPlans = new List<MaintenancePlan>();
        List<MaintenancePlan> extendedPlans = new List<MaintenancePlan>();
        for (SiteCoverage sc : sites) {
            MaintenancePlan existing = planBySite.get(sc.site.Id);
            if (existing != null && sc.endDate != null && existing.EndDate != null && existing.EndDate < sc.endDate) {
                extendedPlans.add(new MaintenancePlan(Id = existing.Id, EndDate = sc.endDate));
            }
            if (existing != null || sc.units.isEmpty()) {
                continue;
            }
            MaintenancePlan mp = new MaintenancePlan(
                AccountId = sc.site.Id,
                LocationId = sc.locationId,
                MaintenancePlanTitle = PLAN_TITLE,
                Description = sc.units.size() + ' rooftop units, quarterly preventive maintenance',
                WorkTypeId = workTypeId,
                StartDate = sc.startDate,
                EndDate = sc.endDate,
                NextSuggestedMaintenanceDate = sc.startDate,
                GenerationTimeframe = 4,
                GenerationTimeframeType = 'Months',
                DoesAutoGenerateWorkOrders = false,
                DoesGenerateUponCompletion = false,
                WorkOrderGenerationMethod = 'WorkOrderLineItemPerAsset',
                SvcApptGenerationMethod = 'SvcApptPerWorkOrder'
            );
            newPlans.add(mp);
            planBySite.put(sc.site.Id, mp);
        }
        insert newPlans;
        update extendedPlans;

        Set<Id> planIds = new Map<Id, MaintenancePlan>(planBySite.values()).keySet();
        Set<Id> maintained = new Set<Id>();
        for (MaintenanceAsset ma : [SELECT AssetId FROM MaintenanceAsset WHERE MaintenancePlanId IN :planIds]) {
            maintained.add(ma.AssetId);
        }
        List<MaintenanceAsset> started = new List<MaintenanceAsset>();
        List<Date> firstVisits = new List<Date>();
        Set<Id> changed = new Set<Id>();
        for (SiteCoverage sc : sites) {
            MaintenancePlan mp = planBySite.get(sc.site.Id);
            if (mp == null) {
                continue;
            }
            for (Asset unit : sc.units) {
                if (maintained.contains(unit.Id)) {
                    continue;
                }
                started.add(new MaintenanceAsset(
                    MaintenancePlanId = mp.Id,
                    AssetId = unit.Id,
                    WorkTypeId = workTypeId,
                    NextSuggestedMaintenanceDate = sc.startDate
                ));
                firstVisits.add(sc.startDate);
                changed.add(mp.Id);
            }
        }
        insert started;
        List<MaintenanceWorkRule> rules = new List<MaintenanceWorkRule>();
        for (Integer i = 0; i < started.size(); i++) {
            rules.add(new MaintenanceWorkRule(
                ParentMaintenanceRecordId = started[i].Id,
                Title = MAINTENANCE_WORK_TYPE,
                WorkTypeId = workTypeId,
                Type = 'Calendar',
                SortOrder = 1,
                RecurrencePattern = QUARTERLY_RULE,
                NextSuggestedMaintenanceDate = firstVisits[i]
            ));
        }
        insert rules;
        return changed;
    }

    /**
     * Generated site visits get the site's address and Location, the service territory and the
     * facility contact; the Work Order trigger calls this before insert.
     */
    public static void fillVisitDefaults(List<WorkOrder> records) {
        Set<Id> planIds = new Set<Id>();
        for (WorkOrder wo : records) {
            if (wo.MaintenancePlanId != null) {
                planIds.add(wo.MaintenancePlanId);
            }
        }
        if (planIds.isEmpty()) {
            return;
        }
        Map<Id, MaintenancePlan> plans = new Map<Id, MaintenancePlan>([
            SELECT Id, AccountId, LocationId, Account.ParentId, Account.BillingStreet, Account.BillingCity,
                Account.BillingState, Account.BillingPostalCode, Account.BillingCountry
            FROM MaintenancePlan WHERE Id IN :planIds AND MaintenancePlanTitle = :PLAN_TITLE
        ]);
        if (plans.isEmpty()) {
            return;
        }
        Set<Id> groupIds = new Set<Id>();
        for (MaintenancePlan mp : plans.values()) {
            groupIds.add(mp.Account.ParentId);
        }
        Map<Id, Id> contactByGroup = new Map<Id, Id>();
        for (Contact c : [
            SELECT Id, AccountId FROM Contact WHERE AccountId IN :groupIds AND Title LIKE '%Facilities%'
            ORDER BY CreatedDate
        ]) {
            if (!contactByGroup.containsKey(c.AccountId)) {
                contactByGroup.put(c.AccountId, c.Id);
            }
        }
        List<ServiceTerritory> territories = [SELECT Id FROM ServiceTerritory WHERE Name = :TERRITORY LIMIT 1];
        for (WorkOrder wo : records) {
            MaintenancePlan mp = plans.get(wo.MaintenancePlanId);
            if (mp == null) {
                continue;
            }
            if (wo.LocationId == null) {
                wo.LocationId = mp.LocationId;
            }
            if (wo.ServiceTerritoryId == null && !territories.isEmpty()) {
                wo.ServiceTerritoryId = territories[0].Id;
            }
            if (String.isBlank(wo.Street)) {
                wo.Street = mp.Account.BillingStreet;
                wo.City = mp.Account.BillingCity;
                wo.State = mp.Account.BillingState;
                wo.PostalCode = mp.Account.BillingPostalCode;
                wo.Country = mp.Account.BillingCountry;
            }
            if (wo.ContactId == null) {
                wo.ContactId = contactByGroup.get(mp.Account.ParentId);
            }
        }
    }

    private static Id workTypeId() {
        List<WorkType> types = [SELECT Id FROM WorkType WHERE Name = :MAINTENANCE_WORK_TYPE LIMIT 1];
        if (types.isEmpty()) {
            throw new IllegalStateException('Work type "' + MAINTENANCE_WORK_TYPE + '" is missing; run insert_hvac_com_fsl_data.');
        }
        return types[0].Id;
    }

    private static Id responseProcessId() {
        List<SlaProcess> processes = [
            SELECT Id FROM SlaProcess WHERE Name = :RLM_HVAC_Coverage.RESPONSE_PROCESS AND IsActive = true LIMIT 1
        ];
        return processes.isEmpty() ? null : processes[0].Id;
    }

    public class IllegalStateException extends Exception {}
}
