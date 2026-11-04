@IsTest
private class RLM_HVAC_BillExplainerTest {
    private static Invoice invoice(String documentNumber, Decimal subtotal, Decimal tax, Decimal balance) {
        return (Invoice) JSON.deserialize(JSON.serialize(new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'Invoice' },
            'Id' => Invoice.SObjectType.getDescribe().getKeyPrefix() + '000000000' + documentNumber.right(3),
            'DocumentNumber' => documentNumber,
            'InvoiceDate' => '2026-10-26',
            'DueDate' => '2026-11-25',
            'TotalAmount' => subtotal,
            'TotalTaxAmount' => tax,
            'TotalAmountWithTax' => subtotal + tax,
            'Balance' => balance
        }), Invoice.class);
    }

    private static InvoiceLine line(String product, Decimal quantity, Decimal unitPrice, Decimal charge, String chargeType,
            String term, String startDate, String endDate, String description) {
        return (InvoiceLine) JSON.deserialize(JSON.serialize(new Map<String, Object>{
            'attributes' => new Map<String, Object>{ 'type' => 'InvoiceLine' },
            'Name' => product,
            'Product2' => new Map<String, Object>{ 'attributes' => new Map<String, Object>{ 'type' => 'Product2' }, 'Name' => product },
            'BillingSchedule' => new Map<String, Object>{ 'attributes' => new Map<String, Object>{ 'type' => 'BillingSchedule' }, 'BillingTermUnit' => term },
            'Quantity' => quantity,
            'UnitPrice' => unitPrice,
            'ChargeAmount' => charge,
            'TaxRate' => 10,
            'RLM_Charge_Type__c' => chargeType,
            'InvoiceLineStartDate' => startDate,
            'InvoiceLineEndDate' => endDate,
            'Description' => description
        }), InvoiceLine.class);
    }

    @IsTest
    static void firstBillShowsTheAgreementTheInitialTuneUpAndTax() {
        List<String> out = RLM_HVAC_BillExplainer.describe(invoice('DOC-000000016', 343, 34.3, 377.3), new List<InvoiceLine>{
            line('Initial Tune-up', 2, 129, 258, 'Milestone Plan', 'BillingMilestonePlan', '2026-10-26', '2026-10-26',
                'Milestone: Initial Tune-up Complete, Percentage: 100.0, Completion date: 2026-10-26'),
            line('Indoor Air Quality', 1, 15, 15, 'Monthly Subscription', 'Month', '2026-10-26', '2026-11-25', null),
            line('Comfort Plus', 2, 35, 70, 'Monthly Subscription', 'Month', '2026-10-26', '2026-11-25', null)
        }, new Map<Id, String>());
        String text = String.join(out, '\n');

        Assert.isTrue(text.contains('$377.30'), text);
        Assert.isTrue(text.contains('Initial Tune-up Complete'), text);
        Assert.isTrue(text.contains('Indoor Air Quality: $15.00 monthly agreement charge for'), text);
        Assert.isTrue(text.contains('Comfort Plus: $70.00 monthly agreement charge (2 systems x $35.00)'), text);
        Assert.isTrue(text.contains('Subtotal $343.00 + tax $34.30 (10%) = $377.30'), text);
    }

    @IsTest
    static void agreementChangeShowsTheCreditAndProration() {
        String credit = RLM_HVAC_BillExplainer.lineText(
            line('Comfort Basic', -1, 19, -17.77, 'Monthly Subscription', 'Month', '2026-10-28', '2026-11-25', null), new Map<Id, String>());
        String partial = RLM_HVAC_BillExplainer.lineText(
            line('Comfort Premier', 1, 45, 22.50, 'Monthly Subscription', 'Month', '2026-11-12', '2026-11-27', null), new Map<Id, String>());
        String repair = RLM_HVAC_BillExplainer.lineText(
            line('Capacitor Replacement', 1, 185, 185, 'One time', 'OneTime', '2026-10-26', '2026-10-26', null), new Map<Id, String>());

        Assert.isTrue(credit.contains('credit of $17.77'), credit);
        Assert.isTrue(credit.contains('after the agreement was changed'), credit);
        Assert.isTrue(partial.contains('prorated from $45.00'), partial);
        Assert.isTrue(repair.contains('one-time service'), repair);
    }

    @IsTest
    static void amountPicksTheMatchingBillOrAllOpenBills() {
        List<Invoice> invoices = new List<Invoice>{
            invoice('DOC-000000016', 333, 33.3, 366.3),
            invoice('DOC-000000015', 179, 17.9, 196.9)
        };
        RLM_HVAC_BillExplainer.Request byAmount = new RLM_HVAC_BillExplainer.Request();
        byAmount.amount = 366;
        RLM_HVAC_BillExplainer.Request byTotal = new RLM_HVAC_BillExplainer.Request();
        byTotal.amount = 563.20;
        RLM_HVAC_BillExplainer.Request unknown = new RLM_HVAC_BillExplainer.Request();
        unknown.amount = 12;
        List<String> notes = new List<String>();

        Assert.areEqual('DOC-000000016', RLM_HVAC_BillExplainer.choose(invoices, byAmount, notes)[0].DocumentNumber);
        Assert.areEqual(2, RLM_HVAC_BillExplainer.choose(invoices, byTotal, notes).size());
        Assert.areEqual('DOC-000000016', RLM_HVAC_BillExplainer.choose(invoices, unknown, notes)[0].DocumentNumber);
        Assert.isTrue(notes[notes.size() - 1].startsWith('No bill matches $12.00'));
    }

    @IsTest
    static void customersWithoutBillsGetAPlainAnswer() {
        insert new Account(Name = 'Bill Explainer Test', ShippingPostalCode = '60540');
        RLM_HVAC_BillExplainer.Request named = new RLM_HVAC_BillExplainer.Request();
        named.accountName = 'Bill Explainer Test';
        RLM_HVAC_BillExplainer.Request missing = new RLM_HVAC_BillExplainer.Request();
        missing.accountName = 'Nobody By This Name';

        List<RLM_HVAC_BillExplainer.Response> responses = RLM_HVAC_BillExplainer.explain(
            new List<RLM_HVAC_BillExplainer.Request>{ named, missing });

        Assert.areEqual('Bill Explainer Test has no posted bills yet.', responses[0].explanation);
        Assert.isTrue(responses[1].explanation.startsWith('I couldn\'t find that customer'));
        Assert.areEqual('$1,234.50', RLM_HVAC_BillExplainer.money(1234.5));
    }

    @IsTest
    static void lookupsByRecordAndInvoiceNumber() {
        Account account = new Account(Name = 'Bill Explainer Zone', ShippingPostalCode = '60540');
        insert account;
        RLM_HVAC_BillExplainer.Request onRecord = new RLM_HVAC_BillExplainer.Request();
        onRecord.accountId = account.Id;
        RLM_HVAC_BillExplainer.Request byNumber = new RLM_HVAC_BillExplainer.Request();
        byNumber.invoiceNumber = 'DOC-NOT-REAL';

        Assert.areEqual('Bill Explainer Zone has no posted bills yet.', RLM_HVAC_BillExplainer.explainOne(onRecord).explanation);
        Assert.isTrue(RLM_HVAC_BillExplainer.explainOne(byNumber).explanation.startsWith('I couldn\'t find'));
        RLM_HVAC_BillExplainer.Request onMissingInvoice = new RLM_HVAC_BillExplainer.Request();
        onMissingInvoice.accountId = Invoice.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        Assert.isTrue(RLM_HVAC_BillExplainer.explainOne(onMissingInvoice).explanation.startsWith('I couldn\'t find'));
        Assert.isTrue(RLM_HVAC_BillExplainer.zoneLine(account).contains('ZIP 60540'));
        Assert.isNull(RLM_HVAC_BillExplainer.zoneLine(new Account(Name = 'No ZIP')));
        Assert.isTrue(RLM_HVAC_BillExplainer.visitsFor(account.Id).isEmpty());
        Invoice inv = invoice('DOC-000000099', 10, 1, 11);
        Assert.isTrue(RLM_HVAC_BillExplainer.linesFor(new List<Invoice>{ inv }).get(inv.Id).isEmpty());
    }
}
