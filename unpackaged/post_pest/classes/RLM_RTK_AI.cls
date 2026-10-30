/**
 * Generative AI for the Rentokil pest field app. Each feature fills one Prompt Builder template
 * (RLM_RTK_* in unpackaged/post_pest_ai) and falls back to the rules when Einstein isn't set up,
 * the call fails, or the reply can't be used. AI only drafts, suggests and explains: technicians
 * confirm findings, customers approve anything they pay for, and prices stay rule and zone based.
 *
 * The Einstein call lives in RLM_RTK_EinsteinGenerator (post_pest_ai) and is found by name, so
 * this bundle deploys and runs on the rules in orgs without generative AI.
 */
public with sharing class RLM_RTK_AI {
    public static final String BRIEF_TEMPLATE = 'RLM_RTK_Visit_Brief';
    public static final String PHOTO_TEMPLATE = 'RLM_RTK_Photo_Finding';
    public static final String NOTES_TEMPLATE = 'RLM_RTK_Notes_Finding';
    public static final String EXPLAIN_TEMPLATE = 'RLM_RTK_Plan_Explanation';
    public static final String SUGGEST_TEMPLATE = 'RLM_RTK_Product_Suggestions';
    public static final String SUMMARY_TEMPLATE = 'RLM_RTK_Visit_Summary';
    private static final String EINSTEIN_GENERATOR = 'RLM_RTK_EinsteinGenerator';
    private static final Integer MAX_PICKS = 3;

    public interface Generator {
        /** The model's reply for a prompt template. Inputs are keyed by the template input API name. */
        String generate(String templateName, Map<String, Object> inputs);
    }

    @TestVisible
    private static Generator generator {
        get {
            if (generator == null) {
                Type einstein = Type.forName(EINSTEIN_GENERATOR);
                generator = einstein == null ? null : (Generator) einstein.newInstance();
            }
            return generator;
        }
        set;
    }

    public class Brief {
        @AuraEnabled public String headline;
        @AuraEnabled public List<String> points = new List<String>();
        @AuraEnabled public List<String> lookFor = new List<String>();
        @AuraEnabled public Datetime generatedAt;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    public class FindingSuggestion {
        @AuraEnabled public String zone;
        @AuraEnabled public String pest;
        @AuraEnabled public String evidence;
        @AuraEnabled public String severity;
        @AuraEnabled public String customerNote;
        @AuraEnabled public String internalNote;
        /** What the model saw in the photo, in a few words. */
        @AuraEnabled public String observation;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    public class Pick {
        @AuraEnabled public String sku;
        @AuraEnabled public String reason;
        public Pick(String sku, String reason) {
            this.sku = sku;
            this.reason = reason;
        }
    }

    public class Option {
        public String sku;
        public String name;
        public String description;
        public Option(String sku, String name, String description) {
            this.sku = sku;
            this.name = name;
            this.description = description;
        }
    }

    public class Summary {
        @AuraEnabled public String text;
        @AuraEnabled public String emailedTo;
        @AuraEnabled public Datetime sentAt;
        @AuraEnabled public String emailError;
        @AuraEnabled public Boolean aiGenerated = false;
    }

    // ---------- 1. Pre-visit brief ----------

    /** The brief for the visit, generated once and kept on the work order so it still shows offline. */
    @AuraEnabled
    public static Brief getBrief(Id recordId, Boolean regenerate) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (regenerate != true && String.isNotBlank(wo.RLM_RTK_AI_Brief__c)) {
                Brief saved = savedBrief(wo.RLM_RTK_AI_Brief__c);
                if (saved != null && (saved.aiGenerated == true || generator == null)) {
                    return saved;
                }
            }
            Facts facts = new Facts(wo);
            Brief brief = aiBrief(facts);
            if (brief == null) {
                brief = ruleBrief(facts);
            }
            brief.generatedAt = Datetime.now();
            update new WorkOrder(
                Id = wo.Id,
                RLM_RTK_AI_Brief__c = JSON.serialize(brief),
                RLM_RTK_AI_Brief_At__c = brief.generatedAt
            );
            return brief;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static Brief savedBrief(String body) {
        try {
            return (Brief) JSON.deserialize(body, Brief.class);
        } catch (Exception e) {
            return null;
        }
    }

    private static Brief aiBrief(Facts facts) {
        Map<String, Object> reply = generateJson(BRIEF_TEMPLATE, new Map<String, Object>{ 'Context' => facts.context() });
        if (reply == null || String.isBlank(asText(reply.get('headline')))) {
            return null;
        }
        Brief brief = new Brief();
        brief.aiGenerated = true;
        brief.headline = asText(reply.get('headline'));
        brief.points = asTexts(reply.get('points'), 5);
        brief.lookFor = asTexts(reply.get('lookFor'), 4);
        return brief;
    }

    private static Brief ruleBrief(Facts facts) {
        Brief brief = new Brief();
        brief.headline = (facts.isTreatment ? 'Treatment visit for ' : 'Inspection visit for ') + facts.customer;
        if (String.isNotBlank(facts.reason)) {
            brief.points.add(facts.reason);
        }
        brief.points.add(facts.plans.isEmpty()
            ? 'No active service plans yet.'
            : 'On ' + String.join(facts.plans, ', ') + ' (' + money(facts.monthlyTotal) + '/mo).');
        if (!facts.pendingChanges.isEmpty()) {
            brief.points.add('Scheduled: ' + facts.pendingChanges[0] + '.');
        }
        if (!facts.pastVisits.isEmpty()) {
            brief.points.add('Last visit: ' + facts.pastVisits[0] + '.');
        }
        if (facts.openBalance > 0) {
            brief.points.add('Open balance ' + money(facts.openBalance) + ' on ' + facts.openInvoices.size()
                + (facts.openInvoices.size() == 1 ? ' invoice.' : ' invoices.'));
        }
        for (RLM_RTK_Finding__c f : facts.findings) {
            if (f.Treatment_Status__c != 'Treated' && brief.lookFor.size() < 4) {
                brief.lookFor.add(describe(f));
            }
        }
        if (brief.lookFor.isEmpty()) {
            brief.lookFor.add(facts.isTreatment
                ? 'Check the perimeter and entry points for new activity.'
                : 'Walk every zone; look for entry points, droppings and standing water.');
        }
        return brief;
    }

    // ---------- 2. Suggestions from photos ----------

    /** Pest, evidence and severity the model sees in a photo on a finding, for the technician to accept or edit. */
    @AuraEnabled
    public static FindingSuggestion suggestFromPhoto(Id findingId, Id documentId) {
        try {
            RLM_RTK_Finding__c f = [
                SELECT Id, Zone__c, Pest__c, Evidence__c, Severity__c FROM RLM_RTK_Finding__c WHERE Id = :findingId
            ];
            if ([SELECT COUNT() FROM ContentDocumentLink
                 WHERE LinkedEntityId = :findingId AND ContentDocumentId = :documentId] == 0) {
                throw new AIException('That photo is not on this finding.');
            }
            String context = 'Area of the property: ' + blankAs(f.Zone__c, 'unknown') + '\n'
                + 'Technician picked so far: pest ' + blankAs(f.Pest__c, 'none') + ', evidence '
                + blankAs(f.Evidence__c, 'none') + ', severity ' + blankAs(f.Severity__c, 'none') + '\n'
                + choices();
            Map<String, Object> reply = generateJson(PHOTO_TEMPLATE, new Map<String, Object>{
                'Photo' => new Map<String, String>{ 'id' => documentId },
                'Context' => context
            });
            return reply == null ? null : toSuggestion(reply, f.Zone__c);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------- 3. Voice notes into findings ----------

    /** Turns what the technician dictated into a draft finding. Keyword matching when AI is unavailable. */
    @AuraEnabled
    public static FindingSuggestion parseNotes(String notes, String zone) {
        try {
            if (String.isBlank(notes)) {
                throw new AIException('Say or type what you see first.');
            }
            Map<String, Object> reply = generateJson(NOTES_TEMPLATE, new Map<String, Object>{
                'Notes' => notes,
                'Context' => 'Area the technician is in: ' + blankAs(zone, 'not picked') + '\n' + choices()
            });
            return reply == null ? keywordFinding(notes, zone) : toSuggestion(reply, zone);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @TestVisible
    private static FindingSuggestion keywordFinding(String notes, String zone) {
        String text = words(notes);
        FindingSuggestion s = new FindingSuggestion();
        s.zone = firstMatch(text, ZONE_WORDS, zone);
        s.pest = firstMatch(text, PEST_WORDS, null);
        s.evidence = firstMatch(text, EVIDENCE_WORDS, null);
        s.severity = firstMatch(text, SEVERITY_WORDS, 'Light');
        s.customerNote = notes.trim();
        return s;
    }

    private static final Map<String, List<String>> ZONE_WORDS = new Map<String, List<String>>{
        'Exterior Perimeter' => new List<String>{ 'perimeter', 'foundation', 'siding', 'eave', 'outside wall' },
        'Garage' => new List<String>{ 'garage' },
        'Kitchen' => new List<String>{ 'kitchen', 'pantry', 'under the sink' },
        'Bathrooms' => new List<String>{ 'bathroom', 'shower', 'toilet' },
        'Living Areas' => new List<String>{ 'living room', 'bedroom', 'baseboard' },
        'Basement / Crawlspace' => new List<String>{ 'basement', 'crawl', 'sill plate', 'joist' },
        'Attic' => new List<String>{ 'attic', 'insulation' },
        'Yard' => new List<String>{ 'yard', 'garden', 'lawn', 'wood pile', 'woodpile', 'mulch' }
    };
    private static final Map<String, List<String>> PEST_WORDS = new Map<String, List<String>>{
        'Termites' => new List<String>{ 'termite', 'mud tube', 'swarmer' },
        'Rodents' => new List<String>{ 'rodent', 'mouse', 'mice', ' rat ', ' rats' },
        'Wasps / Bees' => new List<String>{ 'wasp', ' bee ', ' bees', 'hornet', 'yellow jacket', 'yellowjacket' },
        'Mosquitoes' => new List<String>{ 'mosquito' },
        'Bed Bugs' => new List<String>{ 'bed bug', 'bedbug' },
        'Cockroaches' => new List<String>{ 'roach' },
        'Ants' => new List<String>{ ' ant ', ' ants' },
        'Spiders' => new List<String>{ 'spider', ' web', 'cobweb' }
    };
    private static final Map<String, List<String>> EVIDENCE_WORDS = new Map<String, List<String>>{
        'Nest' => new List<String>{ 'nest' },
        'Droppings' => new List<String>{ 'dropping', 'feces', 'frass' },
        'Entry Point' => new List<String>{ 'gap', 'hole', 'entry', 'crack', 'opening' },
        'Standing Water' => new List<String>{ 'standing water', 'puddle', 'birdbath', 'gutter' },
        'Damage' => new List<String>{ 'damage', 'chewed', 'gnaw', 'hollow', 'mud tube', 'soft wood' },
        'Wood-to-Soil Contact' => new List<String>{ 'wood to soil', 'wood-to-soil', 'soil contact' },
        'Moisture' => new List<String>{ 'moist', 'damp', 'leak', 'humid' },
        'Live Activity' => new List<String>{ 'live', 'crawling', 'active', 'saw a', 'flying' }
    };
    private static final Map<String, List<String>> SEVERITY_WORDS = new Map<String, List<String>>{
        'Heavy' => new List<String>{ 'heavy', 'severe', 'infest', 'lots of', 'everywhere', 'pretty bad', 'really bad', 'serious' },
        'Moderate' => new List<String>{ 'moderate', 'several', 'some ', 'a few' },
        'Light' => new List<String>{ 'light', 'minor', 'one ', 'a little' }
    };

    /** The model sometimes "suggests" a product while saying nothing supports it; those never reach the technician. */
    @TestVisible
    private static Boolean isUnsupported(String reason) {
        String text = ' ' + reason.toLowerCase() + ' ';
        for (String phrase : new List<String>{ ' no ', ' not ', ' none', 'may be', 'might', 'potential', 'consider', 'n\'t ' }) {
            if (text.contains(phrase)) {
                return true;
            }
        }
        return false;
    }

    /** A reason that names a pest must name one the option actually treats. */
    @TestVisible
    private static Boolean covers(Option o, String reason) {
        Set<String> named = pestsIn(reason);
        if (named.isEmpty()) {
            return true;
        }
        named.retainAll(pestsIn(o.name + ' ' + o.description));
        return !named.isEmpty();
    }

    private static Set<String> pestsIn(String text) {
        Set<String> pests = new Set<String>();
        String lower = words(text);
        for (String pest : PEST_WORDS.keySet()) {
            for (String word : PEST_WORDS.get(pest)) {
                if (lower.contains(word)) {
                    pests.add(pest);
                }
            }
        }
        if (lower.contains('general pest')) {
            pests.addAll(new List<String>{ 'Ants', 'Spiders', 'Cockroaches' });
        }
        return pests;
    }

    /** Lowercase with punctuation as spaces and padded, so keywords can anchor on word edges. */
    private static String words(String text) {
        return ' ' + blankAs(text, '').toLowerCase().replaceAll('[^a-z0-9\\- ]', ' ') + ' ';
    }

    private static String firstMatch(String text, Map<String, List<String>> words, String fallback) {
        for (String value : words.keySet()) {
            for (String word : words.get(value)) {
                if (text.contains(word)) {
                    return value;
                }
            }
        }
        return fallback;
    }

    // ---------- 4. Plain-language "why this plan" ----------

    /**
     * Two friendly sentences on why the recommended plan fits, written from the rules' reasons and
     * the findings. Kept on the inspection until the recommendation changes, and on the quote for the proposal.
     */
    @AuraEnabled
    public static String explainPlan(Id inspectionId) {
        try {
            RLM_RTK_Inspection__c inspection = [
                SELECT Id, Account__r.Name, Overall_Severity__c, Recommendation_Summary__c, Plan_Explanation__c,
                    Plan_Explanation_Basis__c, Quote__c
                FROM RLM_RTK_Inspection__c WHERE Id = :inspectionId
            ];
            if (String.isNotBlank(inspection.Plan_Explanation__c)
                && inspection.Plan_Explanation_Basis__c != null
                && inspection.Plan_Explanation_Basis__c.equals(inspection.Recommendation_Summary__c)) {
                return inspection.Plan_Explanation__c;
            }
            List<RLM_RTK_Finding__c> findings = findingsFor(new Set<Id>{ inspectionId });
            List<String> lines = new List<String>{
                'Customer: ' + inspection.Account__r?.Name,
                'Overall severity: ' + blankAs(inspection.Overall_Severity__c, 'Light'),
                'Recommended products and the findings behind them:',
                blankAs(inspection.Recommendation_Summary__c, 'Essential Pest Plan: no active activity found')
            };
            lines.add('Findings:');
            lines.addAll(findingLines(findings, false));
            String text = generate(EXPLAIN_TEMPLATE, new Map<String, Object>{ 'Context' => String.join(lines, '\n') });
            Boolean ai = text != null;
            if (!ai) {
                text = ruleExplanation(inspection.Recommendation_Summary__c);
            }
            update new RLM_RTK_Inspection__c(
                Id = inspection.Id,
                Plan_Explanation__c = text,
                Plan_Explanation_Basis__c = ai ? inspection.Recommendation_Summary__c : null
            );
            if (inspection.Quote__c != null) {
                update new Quote(Id = inspection.Quote__c, RLM_RTK_Plan_Explanation__c = text);
            }
            return text;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @TestVisible
    private static String ruleExplanation(String recommendationSummary) {
        if (String.isBlank(recommendationSummary)) {
            return 'We didn\'t find active pests today, so we recommend the Essential Pest Plan to keep it that way.';
        }
        List<String> sentences = new List<String>();
        for (String line : recommendationSummary.split('\n')) {
            String product = line.substringBefore(':').trim();
            String because = line.substringAfter(':').trim();
            sentences.add(sentences.isEmpty()
                ? 'Based on what we found today, we recommend the ' + product + ', which covers ' + because.toLowerCase() + '.'
                : 'The ' + product + ' takes care of ' + because.toLowerCase() + '.');
        }
        return String.join(sentences, ' ');
    }

    // ---------- 5. Smarter Find & Add and Change the plan ----------

    /**
     * Products the findings' notes call for beyond the fixed rules. Only SKUs from options come
     * back, so the caller prices them as usual and the customer still approves.
     */
    public static List<Pick> suggestProducts(Id accountId, List<Option> options, String kind) {
        List<Pick> picks = new List<Pick>();
        if (options.isEmpty() || accountId == null) {
            return picks;
        }
        List<RLM_RTK_Finding__c> findings = findingsFor(inspectionsFor(accountId));
        if (findings.isEmpty()) {
            return picks;
        }
        Map<String, Option> bySku = new Map<String, Option>();
        List<String> lines = new List<String>{ 'Choose from these ' + kind + ' (SKU | name | what it covers):' };
        for (Option o : options) {
            bySku.put(o.sku, o);
            lines.add(o.sku + ' | ' + o.name + ' | ' + blankAs(o.description, ''));
        }
        lines.add('Findings and notes from this customer\'s visits:');
        lines.addAll(findingLines(findings, true));
        Map<String, Object> reply = generateJson(SUGGEST_TEMPLATE, new Map<String, Object>{ 'Context' => String.join(lines, '\n') });
        Object suggestions = reply == null ? null : reply.get('suggestions');
        if (!(suggestions instanceof List<Object>)) {
            return picks;
        }
        Set<String> seen = new Set<String>();
        for (Object item : (List<Object>) suggestions) {
            if (!(item instanceof Map<String, Object>) || picks.size() == MAX_PICKS) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) item;
            String sku = asText(m.get('sku'));
            String reason = asText(m.get('reason'));
            if (sku != null && bySku.containsKey(sku) && String.isNotBlank(reason) && !isUnsupported(reason)
                    && covers(bySku.get(sku), reason) && seen.add(sku)) {
                picks.add(new Pick(sku, reason.abbreviate(160)));
            }
        }
        return picks;
    }

    // ---------- 6. Post-visit summary ----------

    /** Writes the visit summary once the work order is complete, saves it on the work order and emails the customer. */
    @AuraEnabled
    public static Summary summarizeVisit(Id recordId) {
        try {
            WorkOrder wo = workOrderFor(recordId);
            if (wo.Status != 'Completed') {
                throw new AIException('Complete the visit before sending the summary.');
            }
            Contact contact = contactFor(wo);
            Summary summary = new Summary();
            if (String.isNotBlank(wo.RLM_RTK_Visit_Summary__c) && wo.RLM_RTK_Summary_Sent_At__c != null) {
                summary.text = wo.RLM_RTK_Visit_Summary__c;
                summary.sentAt = wo.RLM_RTK_Summary_Sent_At__c;
                summary.emailedTo = contact?.Email;
                summary.aiGenerated = generator != null;
                return summary;
            }
            Facts facts = new Facts(wo);
            String context = facts.visitContext(contact?.FirstName);
            summary.text = generate(SUMMARY_TEMPLATE, new Map<String, Object>{ 'Context' => context });
            summary.aiGenerated = summary.text != null;
            if (summary.text == null) {
                summary.text = ruleSummary(facts, contact?.FirstName);
            }
            WorkOrder change = new WorkOrder(Id = wo.Id, RLM_RTK_Visit_Summary__c = summary.text.abbreviate(8000));
            if (contact != null && String.isNotBlank(contact.Email)) {
                try {
                    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                    email.setTargetObjectId(contact.Id);
                    email.setSubject('Your Rentokil visit summary · ' + wo.WorkOrderNumber);
                    email.setPlainTextBody(summary.text);
                    email.setSaveAsActivity(true);
                    Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
                    summary.emailedTo = contact.Email;
                    summary.sentAt = Datetime.now();
                    change.RLM_RTK_Summary_Sent_At__c = summary.sentAt;
                } catch (Exception emailFailed) {
                    summary.emailError = 'Saved on the work order, but the email could not be sent: ' + emailFailed.getMessage();
                }
            } else {
                summary.emailError = 'Saved on the work order. The customer has no email address.';
            }
            update change;
            return summary;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static String ruleSummary(Facts facts, String firstName) {
        List<String> lines = new List<String>{ 'Hi ' + blankAs(firstName, 'there') + ',', '' };
        lines.add('Thanks for having us out today. Here\'s a summary of visit ' + facts.workOrderNumber + '.');
        List<String> treated = new List<String>();
        List<String> open = new List<String>();
        for (RLM_RTK_Finding__c f : facts.findings) {
            if (f.Treatment_Status__c == 'Treated') {
                treated.add(describe(f));
            } else {
                open.add(describe(f));
            }
        }
        if (!treated.isEmpty()) {
            lines.add('');
            lines.add('What we treated:');
            for (String t : treated) {
                lines.add('- ' + t);
            }
        }
        if (!facts.visitAddOns.isEmpty()) {
            lines.add('');
            lines.add('Extra services you approved: ' + String.join(facts.visitAddOns, ', ') + '.');
        }
        if (!facts.visitPlanChanges.isEmpty()) {
            lines.add('Plan changes you approved: ' + String.join(facts.visitPlanChanges, '; ') + '.');
        }
        if (!open.isEmpty() && facts.isTreatment) {
            lines.add('');
            lines.add('We\'ll keep an eye on: ' + String.join(open, '; ') + '.');
        }
        if (facts.nextVisit != null) {
            lines.add('');
            lines.add('Your next visit is ' + facts.nextVisit.format('EEEE, MMMM d') + '.');
        }
        lines.add('');
        lines.add('Questions? Just reply to this email.');
        lines.add('Rentokil');
        return String.join(lines, '\n');
    }

    // ---------- facts about a visit and its customer ----------

    private class Facts {
        WorkOrder wo;
        String customer;
        String workOrderNumber;
        Boolean isTreatment;
        String reason;
        List<String> plans = new List<String>();
        Decimal monthlyTotal = 0;
        List<String> pendingChanges = new List<String>();
        List<String> pastVisits = new List<String>();
        List<String> recentAddOns = new List<String>();
        List<String> openInvoices = new List<String>();
        Decimal openBalance = 0;
        List<RLM_RTK_Finding__c> findings = new List<RLM_RTK_Finding__c>();
        List<String> visitAddOns = new List<String>();
        List<String> visitPlanChanges = new List<String>();
        Datetime nextVisit;

        Facts(WorkOrder wo) {
            this.wo = wo;
            customer = wo.Contact?.Name != null ? wo.Contact.Name : wo.Account?.Name;
            workOrderNumber = wo.WorkOrderNumber;
            isTreatment = wo.RLM_Order__c != null || wo.WorkType?.Name != null
                && !wo.WorkType.Name.containsIgnoreCase('inspection');
            reason = String.isNotBlank(wo.Description) ? wo.Description.abbreviate(300) : wo.Subject;
            if (wo.AccountId == null) {
                return;
            }
            loadPlans();
            for (Order o : [
                SELECT Name, EffectiveDate, Description FROM Order
                WHERE AccountId = :wo.AccountId AND Name LIKE 'Plan change:%' AND Status = 'Activated'
                ORDER BY EffectiveDate DESC LIMIT 10
            ]) {
                String text = o.Name.removeStart('Plan change:').trim() + ' from ' + o.EffectiveDate.format();
                if (o.EffectiveDate > Date.today()) {
                    pendingChanges.add(text);
                }
                if (o.Description != null && o.Description.contains('work order ' + wo.WorkOrderNumber)) {
                    visitPlanChanges.add(text);
                }
            }
            for (WorkOrder past : [
                SELECT WorkOrderNumber, Subject, WorkType.Name, EndDate, LastModifiedDate, RLM_RTK_Visit_Summary__c
                FROM WorkOrder
                WHERE AccountId = :wo.AccountId AND Id != :wo.Id AND Status = 'Completed'
                ORDER BY LastModifiedDate DESC LIMIT 4
            ]) {
                Datetime done = past.EndDate != null ? past.EndDate : past.LastModifiedDate;
                String text = blankAs(past.WorkType?.Name, blankAs(past.Subject, 'Visit')) + ' on ' + done.format('MMM d');
                if (String.isNotBlank(past.RLM_RTK_Visit_Summary__c)) {
                    text += ': ' + past.RLM_RTK_Visit_Summary__c.replaceAll('\\s+', ' ').abbreviate(240);
                }
                pastVisits.add(text);
            }
            for (WorkOrderLineItem line : [
                SELECT Subject, UnitPrice, WorkOrderId, RLM_RTK_Approved_At__c FROM WorkOrderLineItem
                WHERE WorkOrder.AccountId = :wo.AccountId AND RLM_RTK_Approved_At__c != null
                ORDER BY RLM_RTK_Approved_At__c DESC LIMIT 6
            ]) {
                String text = line.Subject + ' (' + money(line.UnitPrice) + ')';
                if (line.WorkOrderId == wo.Id) {
                    visitAddOns.add(text);
                } else {
                    recentAddOns.add(text + ' on ' + line.RLM_RTK_Approved_At__c.format('MMM d'));
                }
            }
            for (Invoice inv : [
                SELECT DocumentNumber, Balance, DueDate FROM Invoice
                WHERE BillingAccountId = :wo.AccountId AND Status = 'Posted' AND Balance > 0
                ORDER BY DueDate ASC LIMIT 5
            ]) {
                openInvoices.add(inv.DocumentNumber + ' ' + money(inv.Balance)
                    + (inv.DueDate == null ? '' : ' due ' + inv.DueDate.format()));
                openBalance += inv.Balance;
            }
            findings = findingsFor(wo.RLM_RTK_Inspection__c != null
                ? new Set<Id>{ wo.RLM_RTK_Inspection__c } : inspectionsFor(wo.AccountId));
            for (ServiceAppointment sa : [
                SELECT SchedStartTime FROM ServiceAppointment
                WHERE AccountId = :wo.AccountId AND SchedStartTime > :Datetime.now()
                    AND Status NOT IN ('Completed', 'Canceled', 'Cannot Complete')
                ORDER BY SchedStartTime ASC LIMIT 1
            ]) {
                nextVisit = sa.SchedStartTime;
            }
        }

        void loadPlans() {
            Set<Id> seen = new Set<Id>();
            Map<String, Integer> countByName = new Map<String, Integer>();
            Datetime now = Datetime.now();
            for (AssetStatePeriod period : [
                SELECT AssetId, Asset.Name, Asset.Product2.Name, Quantity, Mrr, Amount, StartDate, EndDate
                FROM AssetStatePeriod
                WHERE Asset.AccountId = :wo.AccountId AND StartDate <= :now
                ORDER BY StartDate DESC
            ]) {
                if (!seen.add(period.AssetId) || period.Quantity == null || period.Quantity <= 0
                    || (period.EndDate != null && period.EndDate < now)) {
                    continue;
                }
                if (period.Mrr == null || period.Mrr <= 0) {
                    continue;
                }
                String name = blankAs(period.Asset.Product2?.Name, period.Asset.Name);
                Integer count = countByName.get(name);
                countByName.put(name, count == null ? 1 : count + 1);
                monthlyTotal += period.Mrr;
            }
            for (String name : countByName.keySet()) {
                Integer count = countByName.get(name);
                plans.add(count > 1 ? name + ' ×' + count : name);
            }
        }

        /** Everything the brief can draw on, as labeled lines. */
        String context() {
            List<String> lines = new List<String>{
                'Customer: ' + customer,
                'Visit: ' + (isTreatment ? 'treatment' : 'inspection') + ' ' + workOrderNumber,
                'Why they called / work order notes: ' + blankAs(reason, 'none'),
                'Active plans: ' + (plans.isEmpty() ? 'none' : String.join(plans, ', ') + ' (' + money(monthlyTotal) + '/mo)'),
                'Scheduled plan changes: ' + (pendingChanges.isEmpty() ? 'none' : String.join(pendingChanges, '; ')),
                'Open invoices: ' + (openInvoices.isEmpty() ? 'none' : String.join(openInvoices, '; ')),
                'Recent one-time services: ' + (recentAddOns.isEmpty() ? 'none' : String.join(recentAddOns, '; ')),
                'Past visits:'
            };
            lines.addAll(pastVisits.isEmpty() ? new List<String>{ '- none' } : bullets(pastVisits));
            lines.add('Findings from inspections and visits:');
            lines.addAll(findingLines(findings, true));
            return String.join(lines, '\n');
        }

        /** What happened on this visit, for the summary. */
        String visitContext(String firstName) {
            List<String> lines = new List<String>{
                'Customer first name: ' + blankAs(firstName, 'there'),
                'Visit: ' + (isTreatment ? 'treatment' : 'inspection') + ' ' + workOrderNumber,
                'Plans now: ' + (plans.isEmpty() ? 'none' : String.join(plans, ', ')),
                'Extra services approved today: ' + (visitAddOns.isEmpty() ? 'none' : String.join(visitAddOns, ', ')),
                'Plan changes approved today: ' + (visitPlanChanges.isEmpty() ? 'none' : String.join(visitPlanChanges, '; ')),
                'Next visit: ' + (nextVisit == null ? 'not scheduled yet' : nextVisit.format('EEEE, MMMM d')),
                'Findings and what was done:'
            };
            lines.addAll(findingLines(findings, false));
            return String.join(lines, '\n');
        }
    }

    // ---------- shared helpers ----------

    @TestVisible
    private static String generate(String templateName, Map<String, Object> inputs) {
        if (generator == null) {
            return null;
        }
        try {
            String text = generator.generate(templateName, inputs);
            return String.isBlank(text) ? null : text.trim();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, templateName + ' failed, using the rules: ' + e.getMessage());
            return null;
        }
    }

    /** The first JSON object in the reply; models sometimes wrap it in a code fence. */
    @TestVisible
    private static Map<String, Object> generateJson(String templateName, Map<String, Object> inputs) {
        String text = generate(templateName, inputs);
        if (text == null) {
            return null;
        }
        Integer start = text.indexOf('{');
        Integer finish = text.lastIndexOf('}');
        if (start < 0 || finish <= start) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(text.substring(start, finish + 1));
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static FindingSuggestion toSuggestion(Map<String, Object> reply, String zone) {
        FindingSuggestion s = new FindingSuggestion();
        s.aiGenerated = true;
        s.zone = allowed(reply.get('zone'), RLM_RTK_Finding__c.Zone__c, zone);
        s.pest = allowed(reply.get('pest'), RLM_RTK_Finding__c.Pest__c, null);
        s.evidence = allowed(reply.get('evidence'), RLM_RTK_Finding__c.Evidence__c, null);
        s.severity = allowed(reply.get('severity'), RLM_RTK_Finding__c.Severity__c, 'Light');
        s.customerNote = asText(reply.get('customerNote'));
        s.internalNote = asText(reply.get('internalNote'));
        s.observation = asText(reply.get('observation'));
        return s;
    }

    /** The picklist value matching the reply, ignoring case; fallback when there's no match. */
    private static String allowed(Object value, Schema.SObjectField field, String fallback) {
        String text = asText(value);
        if (text != null) {
            for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
                if (entry.isActive() && entry.getValue().equalsIgnoreCase(text)) {
                    return entry.getValue();
                }
            }
        }
        return fallback;
    }

    private static String choices() {
        return 'Allowed zone values: ' + values(RLM_RTK_Finding__c.Zone__c) + '\n'
            + 'Allowed pest values: ' + values(RLM_RTK_Finding__c.Pest__c) + '\n'
            + 'Allowed evidence values: ' + values(RLM_RTK_Finding__c.Evidence__c) + '\n'
            + 'Allowed severity values: ' + values(RLM_RTK_Finding__c.Severity__c);
    }

    private static String values(Schema.SObjectField field) {
        List<String> result = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                result.add(entry.getValue());
            }
        }
        return String.join(result, ', ');
    }

    private static Set<Id> inspectionsFor(Id accountId) {
        return new Map<Id, RLM_RTK_Inspection__c>([
            SELECT Id FROM RLM_RTK_Inspection__c WHERE Account__c = :accountId ORDER BY CreatedDate DESC LIMIT 3
        ]).keySet();
    }

    private static List<RLM_RTK_Finding__c> findingsFor(Set<Id> inspectionIds) {
        return [
            SELECT Id, Zone__c, Pest__c, Evidence__c, Severity__c, Customer_Note__c, Internal_Note__c,
                Treatment_Status__c, Treatment_Note__c, Treated_On__c
            FROM RLM_RTK_Finding__c WHERE Inspection__c IN :inspectionIds
            ORDER BY CreatedDate DESC LIMIT 20
        ];
    }

    private static List<String> findingLines(List<RLM_RTK_Finding__c> findings, Boolean includeInternal) {
        if (findings.isEmpty()) {
            return new List<String>{ '- none' };
        }
        List<String> lines = new List<String>();
        for (RLM_RTK_Finding__c f : findings) {
            String line = '- ' + describe(f) + '; treatment: ' + blankAs(f.Treatment_Status__c, 'Open');
            if (String.isNotBlank(f.Customer_Note__c)) {
                line += '; note: ' + f.Customer_Note__c;
            }
            if (includeInternal && String.isNotBlank(f.Internal_Note__c)) {
                line += '; technician note: ' + f.Internal_Note__c;
            }
            if (String.isNotBlank(f.Treatment_Note__c)) {
                line += '; treatment note: ' + f.Treatment_Note__c;
            }
            lines.add(line.abbreviate(400));
        }
        return lines;
    }

    private static String describe(RLM_RTK_Finding__c f) {
        List<String> what = new List<String>();
        for (String part : new List<String>{ f.Pest__c, f.Evidence__c }) {
            if (String.isNotBlank(part)) {
                what.add(part.toLowerCase());
            }
        }
        return blankAs(f.Zone__c, 'Property') + ': ' + (what.isEmpty() ? 'observation' : String.join(what, ', '))
            + (String.isBlank(f.Severity__c) ? '' : ' (' + f.Severity__c.toLowerCase() + ')');
    }

    private static List<String> bullets(List<String> items) {
        List<String> result = new List<String>();
        for (String item : items) {
            result.add('- ' + item);
        }
        return result;
    }

    private static Contact contactFor(WorkOrder wo) {
        if (wo.ContactId != null && String.isNotBlank(wo.Contact.Email)) {
            return wo.Contact;
        }
        List<Contact> contacts = [
            SELECT Id, FirstName, Name, Email FROM Contact
            WHERE AccountId = :wo.AccountId AND Email != null ORDER BY CreatedDate ASC LIMIT 1
        ];
        return contacts.isEmpty() ? wo.Contact : contacts[0];
    }

    private static WorkOrder workOrderFor(Id recordId) {
        if (recordId == null) {
            throw new AIException('Open this from a service appointment or work order.');
        }
        Id workOrderId = recordId;
        if (recordId.getSobjectType() == ServiceAppointment.SObjectType) {
            workOrderId = [SELECT ParentRecordId FROM ServiceAppointment WHERE Id = :recordId].ParentRecordId;
        }
        if (workOrderId == null || workOrderId.getSobjectType() != WorkOrder.SObjectType) {
            throw new AIException('Open this from a service appointment or work order.');
        }
        return [
            SELECT Id, WorkOrderNumber, Subject, Description, Status, AccountId, Account.Name, ContactId,
                Contact.Name, Contact.FirstName, Contact.Email, WorkType.Name, RLM_Order__c, RLM_RTK_Inspection__c,
                RLM_RTK_AI_Brief__c, RLM_RTK_Visit_Summary__c, RLM_RTK_Summary_Sent_At__c
            FROM WorkOrder WHERE Id = :workOrderId
        ];
    }

    private static String asText(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return String.isBlank(text) || text.equalsIgnoreCase('null') ? null : text;
    }

    private static List<String> asTexts(Object value, Integer max) {
        List<String> result = new List<String>();
        if (value instanceof List<Object>) {
            for (Object item : (List<Object>) value) {
                String text = asText(item);
                if (text != null && result.size() < max) {
                    result.add(text);
                }
            }
        }
        return result;
    }

    private static String blankAs(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static String money(Decimal value) {
        Decimal amount = value == null ? 0 : value.setScale(2);
        return '$' + (amount == amount.round(System.RoundingMode.DOWN) ? String.valueOf(amount.intValue()) : String.valueOf(amount));
    }

    public class AIException extends Exception {}

    private static AuraHandledException auraError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }
}
