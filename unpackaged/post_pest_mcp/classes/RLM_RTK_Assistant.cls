/**
 * Business operations the Verdant Field Assistant needs beyond the Field Service screens: booking a
 * caller's free inspection or a re-service, the technician's schedule for a day, and read-only
 * summaries of a customer and a quote. Everything else the assistant does goes through the same Apex
 * as the screens (see RLM_RTK_AssistantApi).
 */
public with sharing class RLM_RTK_Assistant {
    public static final String TERRITORY = 'Bloomingdale IL';
    private static final Set<String> CLOSED = new Set<String>{ 'Completed', 'Closed', 'Canceled', 'Cannot Complete' };

    public class Caller {
        public String name;
        public String street;
        public String city;
        public String state;
        public String postalCode;
        public String phone;
        public String email;
        public String description;
    }

    public class Booking {
        public Id accountId;
        public String accountName;
        public Boolean newCustomer = false;
        public Id workOrderId;
        public String workOrderNumber;
        public String workType;
        public Id appointmentId;
        public String appointmentNumber;
        public Datetime startTime;
        public Datetime endTime;
        public String coverage;
        public String guarantee;
        public Datetime responseDue;
    }

    public class Visit {
        public Id appointmentId;
        public String appointmentNumber;
        public String status;
        public Datetime startTime;
        public Datetime endTime;
        public Id workOrderId;
        public String workOrderNumber;
        public String workType;
        public String subject;
        public String description;
        public Id accountId;
        public String accountName;
        public String address;
        public String coverage;
        public String reportedPest;
        public Decimal latitude;
        public Decimal longitude;
    }

    public class Plan {
        public String name;
        public String sku;
        public Decimal monthlyPrice;
        public Date since;
    }

    public class CustomerSummary {
        public Id accountId;
        public String name;
        public String address;
        public String postalCode;
        public String contactName;
        public String phone;
        public String email;
        public Date customerSince;
        public List<Plan> plans = new List<Plan>();
        public Decimal monthlyTotal = 0;
        public List<String> scheduledChanges = new List<String>();
        public List<String> guarantees = new List<String>();
        public List<String> openVisits = new List<String>();
        public List<String> recentVisits = new List<String>();
        public List<String> invoices = new List<String>();
        public Decimal openBalance = 0;
        public Id latestInspectionId;
        public String latestInspectionStatus;
        public Id latestQuoteId;
    }

    public class Match {
        public Id accountId;
        public String name;
        public String address;
        public Boolean hasPlans = false;
    }

    public class QuoteLine {
        public String product;
        public String sku;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal totalPrice;
        public String billing;
        public String description;
    }

    public class QuoteDetails {
        public Id quoteId;
        public String quoteNumber;
        public String name;
        public String status;
        public String accountName;
        public Decimal monthlyTotal;
        public Decimal oneTimeTotal;
        public Decimal totalPrice;
        public String planExplanation;
        public String signedBy;
        public Datetime signedAt;
        public String proposalTitle;
        public Id proposalDocumentId;
        public List<QuoteLine> lines = new List<QuoteLine>();
    }

    // ---------- intake ----------

    /** Books a new caller's free Pest Inspection, dispatched to the running technician. Re-booking moves the open visit. */
    public static Booking bookInspection(Caller caller, Date day, Integer hour) {
        if (caller == null || String.isBlank(caller.name) || String.isBlank(caller.street)) {
            throw new AssistantException('A caller needs a name and a street address.');
        }
        String name = caller.name.trim();
        Booking booking = new Booking();
        List<Account> existing = [
            SELECT Id, Name, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode FROM Account
            WHERE Name = :name AND (NOT Name LIKE 'zz Archived%') LIMIT 1
        ];
        Account account;
        if (existing.isEmpty()) {
            String city = String.isBlank(caller.city) ? 'Bloomingdale' : caller.city.trim();
            String state = String.isBlank(caller.state) ? 'IL' : caller.state.trim();
            String postal = String.isBlank(caller.postalCode) ? '60108' : caller.postalCode.trim();
            account = new Account(
                Name = name, RLM_RTK_Demo_Run__c = Datetime.now(),
                ShippingStreet = caller.street.trim(), ShippingCity = city, ShippingState = state,
                ShippingPostalCode = postal, ShippingCountry = 'United States',
                BillingStreet = caller.street.trim(), BillingCity = city, BillingState = state,
                BillingPostalCode = postal, BillingCountry = 'United States'
            );
            insertAllowingDuplicates(account);
            booking.newCustomer = true;
        } else {
            account = existing[0];
            if ([SELECT COUNT() FROM Asset WHERE AccountId = :account.Id AND Product2.StockKeepingUnit LIKE 'RTK-%'] > 0) {
                throw new AssistantException(name + ' is already a customer with a plan. Book a re-service instead.');
            }
        }
        Id contactId = contactFor(account.Id, name, caller.phone, caller.email);

        WorkType inspectionType = workType('Pest Inspection');
        ServiceTerritory territory = territory();
        List<WorkOrder> open = [
            SELECT Id, RLM_RTK_Inspection__r.Status__c FROM WorkOrder
            WHERE AccountId = :account.Id AND WorkTypeId = :inspectionType.Id AND RLM_Order__c = null
                AND Status NOT IN :CLOSED
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        WorkOrder wo;
        if (open.isEmpty() || open[0].RLM_RTK_Inspection__r?.Status__c == 'Accepted') {
            wo = new WorkOrder(
                AccountId = account.Id, ContactId = contactId, WorkTypeId = inspectionType.Id,
                ServiceTerritoryId = territory.Id, Subject = 'Free Pest Inspection',
                Description = String.isBlank(caller.description) ? 'Caller asked for a free pest inspection.' : caller.description,
                Street = account.ShippingStreet, City = account.ShippingCity, State = account.ShippingState,
                PostalCode = account.ShippingPostalCode, Country = 'United States'
            );
            insert wo;
        } else {
            wo = open[0];
            if (String.isNotBlank(caller.description)) {
                update new WorkOrder(Id = wo.Id, Description = caller.description);
            }
        }
        ServiceAppointment sa = dispatch(wo.Id, inspectionType, territory, day, hour, 'Free Pest Inspection');
        return fill(booking, account.Id, wo.Id, sa.Id);
    }

    /** Books a re-service for an existing customer; coverage decides whether it's free and gets the response milestone. */
    public static Booking bookReservice(Id accountId, String pest, String description, Date day, Integer hour) {
        if (accountId == null || String.isBlank(pest)) {
            throw new AssistantException('A re-service needs the customer and the pest they reported.');
        }
        Account account = [
            SELECT Id, Name, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode,
                (SELECT Id FROM Contacts ORDER BY CreatedDate LIMIT 1)
            FROM Account WHERE Id = :accountId
        ];
        WorkType reservice = workType('Pest Re-service');
        ServiceTerritory territory = territory();
        List<WorkOrder> open = [
            SELECT Id FROM WorkOrder WHERE AccountId = :account.Id AND WorkTypeId = :reservice.Id
                AND Status NOT IN :CLOSED LIMIT 1
        ];
        WorkOrder wo;
        if (open.isEmpty()) {
            wo = new WorkOrder(
                AccountId = account.Id, ContactId = account.Contacts.isEmpty() ? null : account.Contacts[0].Id,
                WorkTypeId = reservice.Id, ServiceTerritoryId = territory.Id, RLM_RTK_Reported_Pest__c = pest,
                Subject = 'Re-service: ' + pest.toLowerCase(),
                Description = String.isBlank(description) ? 'Customer reports ' + pest.toLowerCase() + ' again.' : description,
                Street = account.ShippingStreet, City = account.ShippingCity, State = account.ShippingState,
                PostalCode = account.ShippingPostalCode, Country = 'United States'
            );
            insert wo;
        } else {
            wo = new WorkOrder(Id = open[0].Id, RLM_RTK_Reported_Pest__c = pest);
            if (String.isNotBlank(description)) {
                wo.Description = description;
            }
            update wo;
        }
        ServiceAppointment sa = dispatch(wo.Id, reservice, territory, day, hour, 'Pest Re-service');
        return fill(new Booking(), account.Id, wo.Id, sa.Id);
    }

    // ---------- reads ----------

    /** The running technician's appointments on a day, on the territory's clock; archived demo runs are left out. */
    public static List<Visit> schedule(Date day) {
        TimeZone zone = zoneOf(territory());
        Datetime dayStart = zonedStart(day, 0, zone);
        Datetime dayEnd = zonedStart(day.addDays(1), 0, zone);
        Id resourceId = technician().Id;
        List<ServiceAppointment> appointments = [
            SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime, ParentRecordId
            FROM ServiceAppointment
            WHERE Id IN (SELECT ServiceAppointmentId FROM AssignedResource WHERE ServiceResourceId = :resourceId)
                AND SchedStartTime >= :dayStart AND SchedStartTime < :dayEnd
                AND Status NOT IN ('Canceled', 'Cannot Complete')
            ORDER BY SchedStartTime
        ];
        Set<Id> workOrderIds = new Set<Id>();
        for (ServiceAppointment sa : appointments) {
            workOrderIds.add(sa.ParentRecordId);
        }
        Map<Id, WorkOrder> workOrders = new Map<Id, WorkOrder>([
            SELECT Id, WorkOrderNumber, WorkType.Name, Subject, Description, AccountId, Account.Name,
                Street, City, State, PostalCode, Latitude, Longitude, RLM_Service_Coverage__c, RLM_RTK_Reported_Pest__c
            FROM WorkOrder WHERE Id IN :workOrderIds AND (NOT Account.Name LIKE 'zz Archived%')
        ]);
        List<Visit> visits = new List<Visit>();
        for (ServiceAppointment sa : appointments) {
            WorkOrder wo = workOrders.get(sa.ParentRecordId);
            if (wo == null) {
                continue;
            }
            Visit v = new Visit();
            v.appointmentId = sa.Id;
            v.appointmentNumber = sa.AppointmentNumber;
            v.status = sa.Status;
            v.startTime = sa.SchedStartTime;
            v.endTime = sa.SchedEndTime;
            v.workOrderId = wo.Id;
            v.workOrderNumber = wo.WorkOrderNumber;
            v.workType = wo.WorkType?.Name;
            v.subject = wo.Subject;
            v.description = wo.Description;
            v.accountId = wo.AccountId;
            v.accountName = wo.Account?.Name;
            v.address = joinAddress(wo.Street, wo.City, wo.State, wo.PostalCode);
            v.coverage = wo.RLM_Service_Coverage__c;
            v.reportedPest = wo.RLM_RTK_Reported_Pest__c;
            v.latitude = wo.Latitude;
            v.longitude = wo.Longitude;
            visits.add(v);
        }
        return visits;
    }

    /** Customers whose name contains the search text, archived demo runs excluded. */
    public static List<Match> findCustomers(String search) {
        if (String.isBlank(search)) {
            throw new AssistantException('Say which customer to look for.');
        }
        String pattern = '%' + search.trim() + '%';
        List<Match> matches = new List<Match>();
        for (Account a : [
            SELECT Id, Name, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode,
                (SELECT Id FROM Assets WHERE Product2.StockKeepingUnit LIKE 'RTK-%' LIMIT 1)
            FROM Account WHERE Name LIKE :pattern AND (NOT Name LIKE 'zz Archived%')
            ORDER BY Name LIMIT 10
        ]) {
            Match m = new Match();
            m.accountId = a.Id;
            m.name = a.Name;
            m.address = joinAddress(a.ShippingStreet, a.ShippingCity, a.ShippingState, a.ShippingPostalCode);
            m.hasPlans = !a.Assets.isEmpty();
            matches.add(m);
        }
        return matches;
    }

    /** Plans, guarantees, visits, invoices and the latest inspection for a customer. */
    public static CustomerSummary customerSummary(Id accountId) {
        Account a = [
            SELECT Id, Name, CreatedDate, ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode,
                (SELECT Name, Phone, Email FROM Contacts ORDER BY CreatedDate LIMIT 1)
            FROM Account WHERE Id = :accountId
        ];
        CustomerSummary s = new CustomerSummary();
        s.accountId = a.Id;
        s.name = a.Name;
        s.address = joinAddress(a.ShippingStreet, a.ShippingCity, a.ShippingState, a.ShippingPostalCode);
        s.postalCode = a.ShippingPostalCode;
        if (!a.Contacts.isEmpty()) {
            s.contactName = a.Contacts[0].Name;
            s.phone = a.Contacts[0].Phone;
            s.email = a.Contacts[0].Email;
        }

        Datetime now = Datetime.now();
        Map<Id, AssetStatePeriod> current = new Map<Id, AssetStatePeriod>();
        for (AssetStatePeriod p : [
            SELECT AssetId, Asset.Product2.Name, Asset.Product2.StockKeepingUnit, StartDate, Quantity, Mrr
            FROM AssetStatePeriod
            WHERE Asset.AccountId = :accountId AND Asset.Product2.StockKeepingUnit LIKE 'RTK-%' AND StartDate <= :now
            ORDER BY StartDate
        ]) {
            current.put(p.AssetId, p);
        }
        for (AssetStatePeriod p : current.values()) {
            Date since = p.StartDate.dateGmt();
            if (s.customerSince == null || since < s.customerSince) {
                s.customerSince = since;
            }
            if (p.Quantity == null || p.Quantity <= 0 || p.Mrr == null || p.Mrr == 0) {
                continue;
            }
            Plan plan = new Plan();
            plan.name = p.Asset.Product2.Name;
            plan.sku = p.Asset.Product2.StockKeepingUnit;
            plan.monthlyPrice = (p.Mrr / p.Quantity).setScale(2);
            plan.since = since;
            s.plans.add(plan);
            s.monthlyTotal += plan.monthlyPrice;
        }
        for (Order o : [
            SELECT Name, EffectiveDate FROM Order
            WHERE AccountId = :accountId AND Name LIKE 'Plan change:%' AND EffectiveDate > TODAY ORDER BY EffectiveDate
        ]) {
            s.scheduledChanges.add(o.Name.removeStart('Plan change: ') + ' from ' + o.EffectiveDate.format());
        }
        for (Entitlement e : [
            SELECT Name, RLM_RTK_Covered_Pests__c, StartDate, EndDate FROM Entitlement
            WHERE AccountId = :accountId AND RLM_RTK_Covered_Pests__c != null AND (EndDate = null OR EndDate >= TODAY)
            ORDER BY StartDate
        ]) {
            s.guarantees.add(e.Name + ' covers ' + e.RLM_RTK_Covered_Pests__c.replace(';', ', ')
                + (e.StartDate > Date.today() && !e.Name.contains(' from ') ? ' from ' + e.StartDate.format() : '')
                + (e.EndDate == null ? '' : ' until ' + e.EndDate.format()));
        }
        for (WorkOrder wo : [
            SELECT WorkOrderNumber, WorkType.Name, Status, EndDate,
                (SELECT AppointmentNumber, SchedStartTime FROM ServiceAppointments ORDER BY SchedStartTime ASC NULLS LAST LIMIT 1)
            FROM WorkOrder WHERE AccountId = :accountId ORDER BY CreatedDate DESC LIMIT 20
        ]) {
            String label = wo.WorkType?.Name + ' ' + wo.WorkOrderNumber;
            if (wo.Status == 'Completed') {
                if (s.recentVisits.size() < 3) {
                    s.recentVisits.add(label + ' completed' + (wo.EndDate == null ? '' : ' ' + wo.EndDate.format()));
                }
            } else if (!CLOSED.contains(wo.Status)) {
                Datetime next = wo.ServiceAppointments.isEmpty() ? null : wo.ServiceAppointments[0].SchedStartTime;
                s.openVisits.add(label + ' (' + wo.Status + ')' + (next == null ? ', not scheduled' : ', scheduled ' + next.format()));
            }
        }
        for (Invoice inv : [
            SELECT DocumentNumber, InvoiceDate, TotalAmountWithTax, Balance FROM Invoice
            WHERE BillingAccountId = :accountId AND Status = 'Posted' ORDER BY InvoiceDate DESC LIMIT 10
        ]) {
            s.invoices.add(inv.DocumentNumber + ' ' + inv.InvoiceDate.format() + ': ' + RLM_RTK_FieldQuote.money(inv.TotalAmountWithTax ?? 0)
                + ((inv.Balance ?? 0) > 0 ? ', ' + RLM_RTK_FieldQuote.money(inv.Balance) + ' owed' : ', paid'));
            s.openBalance += inv.Balance ?? 0;
        }
        for (RLM_RTK_Inspection__c inspection : [
            SELECT Id, Status__c, Quote__c FROM RLM_RTK_Inspection__c WHERE Account__c = :accountId ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            s.latestInspectionId = inspection.Id;
            s.latestInspectionStatus = inspection.Status__c;
            s.latestQuoteId = inspection.Quote__c;
        }
        return s;
    }

    /** The quote's lines and totals as Salesforce priced them, plus its signature and proposal. */
    public static QuoteDetails quoteDetails(Id quoteId) {
        Quote q = [
            SELECT Id, QuoteNumber, Name, Status, Account.Name, TotalPrice, RLM_RTK_Monthly_Total__c, RLM_RTK_One_Time_Total__c,
                RLM_RTK_Plan_Explanation__c, RLM_Demo_Signed_By__c, RLM_Demo_Signed_At__c,
                (SELECT Product2.Name, Product2.StockKeepingUnit, Quantity, UnitPrice, TotalPrice, BillingFrequency, Description
                 FROM QuoteLineItems ORDER BY CreatedDate)
            FROM Quote WHERE Id = :quoteId
        ];
        QuoteDetails d = new QuoteDetails();
        d.quoteId = q.Id;
        d.quoteNumber = q.QuoteNumber;
        d.name = q.Name;
        d.status = q.Status;
        d.accountName = q.Account?.Name;
        d.totalPrice = q.TotalPrice;
        d.monthlyTotal = q.RLM_RTK_Monthly_Total__c;
        d.oneTimeTotal = q.RLM_RTK_One_Time_Total__c;
        d.planExplanation = q.RLM_RTK_Plan_Explanation__c;
        d.signedBy = q.RLM_Demo_Signed_By__c;
        d.signedAt = q.RLM_Demo_Signed_At__c;
        for (QuoteLineItem line : q.QuoteLineItems) {
            QuoteLine l = new QuoteLine();
            l.product = line.Product2?.Name;
            l.sku = line.Product2?.StockKeepingUnit;
            l.quantity = line.Quantity;
            l.unitPrice = line.UnitPrice;
            l.totalPrice = line.TotalPrice;
            l.billing = line.BillingFrequency == null ? 'One-time' : line.BillingFrequency;
            l.description = line.Description;
            d.lines.add(l);
        }
        RLM_SignAndPay.ProposalDoc proposal = RLM_SignAndPay.findLatestProposal(quoteId);
        if (proposal != null) {
            d.proposalTitle = proposal.title;
            d.proposalDocumentId = proposal.contentDocumentId;
        }
        return d;
    }

    // ---------- helpers ----------

    private static Booking fill(Booking booking, Id accountId, Id workOrderId, Id appointmentId) {
        WorkOrder wo = [
            SELECT Id, WorkOrderNumber, WorkType.Name, Account.Name, RLM_Service_Coverage__c, Entitlement.Name
            FROM WorkOrder WHERE Id = :workOrderId
        ];
        ServiceAppointment sa = [SELECT AppointmentNumber, SchedStartTime, SchedEndTime FROM ServiceAppointment WHERE Id = :appointmentId];
        booking.accountId = accountId;
        booking.accountName = wo.Account?.Name;
        booking.workOrderId = wo.Id;
        booking.workOrderNumber = wo.WorkOrderNumber;
        booking.workType = wo.WorkType?.Name;
        booking.appointmentId = appointmentId;
        booking.appointmentNumber = sa.AppointmentNumber;
        booking.startTime = sa.SchedStartTime;
        booking.endTime = sa.SchedEndTime;
        booking.coverage = wo.RLM_Service_Coverage__c;
        booking.guarantee = wo.Entitlement?.Name;
        for (EntityMilestone m : [
            SELECT TargetDate FROM EntityMilestone WHERE ParentEntityId = :wo.Id AND IsCompleted = false ORDER BY TargetDate LIMIT 1
        ]) {
            booking.responseDue = m.TargetDate;
        }
        return booking;
    }

    /** Schedules the work order's first appointment at the hour on the territory's clock and assigns the running technician. */
    private static ServiceAppointment dispatch(Id workOrderId, WorkType type, ServiceTerritory territory, Date day, Integer hour, String subject) {
        ServiceResource tech = technician();
        Date visitDay = day == null ? Date.today().addDays(1) : day;
        Integer visitHour = hour == null ? 10 : hour;
        if (visitHour < 0 || visitHour > 23) {
            throw new AssistantException('Pick an hour between 0 and 23.');
        }
        Datetime startTime = zonedStart(visitDay, visitHour, zoneOf(territory));
        if (startTime < Datetime.now()) {
            throw new AssistantException('Pick a time in the future.');
        }
        Integer minutes = type.EstimatedDuration == null ? 60 : (Integer) (type.EstimatedDuration * 60);
        List<ServiceAppointment> existing = [
            SELECT Id FROM ServiceAppointment WHERE ParentRecordId = :workOrderId ORDER BY CreatedDate ASC LIMIT 1
        ];
        ServiceAppointment sa = existing.isEmpty() ? new ServiceAppointment(ParentRecordId = workOrderId) : existing[0];
        sa.EarliestStartTime = startTime.addHours(-2);
        sa.DueDate = startTime.addDays(2);
        sa.SchedStartTime = startTime;
        sa.SchedEndTime = startTime.addMinutes(minutes);
        sa.ArrivalWindowStartTime = startTime;
        sa.ArrivalWindowEndTime = startTime.addHours(1);
        sa.ServiceTerritoryId = territory.Id;
        sa.Subject = subject;
        sa.Status = 'Dispatched';
        upsert sa;
        if ([SELECT COUNT() FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id AND ServiceResourceId = :tech.Id] == 0) {
            insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = tech.Id);
        }
        return sa;
    }

    private static Id contactFor(Id accountId, String name, String phone, String email) {
        List<Contact> contacts = [SELECT Id, Phone, Email FROM Contact WHERE AccountId = :accountId ORDER BY CreatedDate LIMIT 1];
        if (!contacts.isEmpty()) {
            Contact c = contacts[0];
            Boolean changed = false;
            if (String.isNotBlank(phone) && c.Phone != phone) {
                c.Phone = phone;
                changed = true;
            }
            if (String.isNotBlank(email) && c.Email != email) {
                c.Email = email;
                changed = true;
            }
            if (changed) {
                update c;
            }
            return c.Id;
        }
        String first = name.contains(' ') ? name.substringBefore(' ') : null;
        String last = name.contains(' ') ? name.substringAfter(' ') : name;
        Contact c = new Contact(AccountId = accountId, FirstName = first, LastName = last,
            Phone = String.isBlank(phone) ? null : phone,
            Email = String.isNotBlank(email) ? email
                : (name.toLowerCase().replaceAll('[^a-z ]', '').trim().replace(' ', '.') + '@example.com'));
        insertAllowingDuplicates(c);
        return c.Id;
    }

    private static void insertAllowingDuplicates(SObject record) {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.SaveResult result = Database.insert(record, dml);
        if (!result.isSuccess()) {
            throw new AssistantException(result.getErrors()[0].getMessage());
        }
    }

    private static WorkType workType(String name) {
        List<WorkType> types = [SELECT Id, EstimatedDuration FROM WorkType WHERE Name = :name LIMIT 1];
        if (types.isEmpty()) {
            throw new AssistantException('Work type ' + name + ' is missing. Run setup_rtk_foundation.');
        }
        return types[0];
    }

    private static ServiceTerritory territory() {
        List<ServiceTerritory> territories = [
            SELECT Id, OperatingHours.TimeZone FROM ServiceTerritory WHERE Name = :TERRITORY LIMIT 1
        ];
        if (territories.isEmpty()) {
            throw new AssistantException('Service territory ' + TERRITORY + ' is missing. Run insert_pest_fsl_data.');
        }
        return territories[0];
    }

    private static ServiceResource technician() {
        List<ServiceResource> resources = [
            SELECT Id FROM ServiceResource WHERE RelatedRecordId = :UserInfo.getUserId() AND IsActive = true LIMIT 1
        ];
        if (resources.isEmpty()) {
            throw new AssistantException('You are not set up as a service resource. Run setup_rtk_foundation.');
        }
        return resources[0];
    }

    private static TimeZone zoneOf(ServiceTerritory territory) {
        return territory.OperatingHours?.TimeZone == null
            ? UserInfo.getTimeZone() : TimeZone.getTimeZone(territory.OperatingHours.TimeZone);
    }

    /** The instant a wall-clock hour on a day starts in the given zone. */
    @TestVisible
    private static Datetime zonedStart(Date day, Integer hour, TimeZone zone) {
        Datetime wall = Datetime.newInstanceGmt(day, Time.newInstance(hour, 0, 0, 0));
        return wall.addSeconds(-zone.getOffset(wall) / 1000);
    }

    private static String joinAddress(String street, String city, String state, String postalCode) {
        List<String> parts = new List<String>();
        for (String part : new List<String>{ street, city, String.join(new List<String>{ state ?? '', postalCode ?? '' }, ' ').trim() }) {
            if (String.isNotBlank(part)) {
                parts.add(part);
            }
        }
        return String.join(parts, ', ');
    }

    public class AssistantException extends Exception {}
}
