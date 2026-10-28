@IsTest
private class RLM_RTK_BillExplainerTest {
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
    static void firstBillShowsPlansTheInitialServiceAndTax() {
        List<String> out = RLM_RTK_BillExplainer.describe(invoice('DOC-000000016', 333, 33.3, 366.3), new List<InvoiceLine>{
            line('Initial Service', 1, 199, 199, 'Milestone Plan', 'BillingMilestonePlan', '2026-10-26', '2026-10-26',
                'Milestone: Initial Treatment Complete, Percentage: 100.0, Completion date: 2026-10-26'),
            line('Seasonal Mosquito Plan', 1, 69, 69, 'Monthly Subscription', 'Month', '2026-10-26', '2026-11-25', null),
            line('Essential Pest Plan', 1, 65, 65, 'Monthly Subscription', 'Month', '2026-10-26', '2026-11-25', null)
        }, new Map<Id, String>());
        String text = String.join(out, '\n');

        Assert.isTrue(text.contains('$366.30'), text);
        Assert.isTrue(text.contains('Initial Treatment Complete'), text);
        Assert.isTrue(text.contains('Seasonal Mosquito Plan: $69.00 monthly plan charge'), text);
        Assert.isTrue(text.contains('Subtotal $333.00 + tax $33.30 (10%) = $366.30'), text);
    }

    @IsTest
    static void planChangeShowsTheCreditAndProration() {
        String credit = RLM_RTK_BillExplainer.lineText(
            line('Essential Pest Plan', -1, 65, -60.81, 'Monthly Subscription', 'Month', '2026-10-28', '2026-11-25', null), new Map<Id, String>());
        String partial = RLM_RTK_BillExplainer.lineText(
            line('Home Protection Plus', 1, 79, 40, 'Monthly Subscription', 'Month', '2026-11-12', '2026-11-27', null), new Map<Id, String>());
        String addOn = RLM_RTK_BillExplainer.lineText(
            line('Wasp & Hornet Nest Removal', 1, 179, 179, 'One time', 'OneTime', '2026-10-26', '2026-10-26', null), new Map<Id, String>());

        Assert.isTrue(credit.contains('credit of $60.81'), credit);
        Assert.isTrue(partial.contains('prorated from $79.00'), partial);
        Assert.isTrue(addOn.contains('one-time service'), addOn);
    }

    @IsTest
    static void amountPicksTheMatchingBillOrAllOpenBills() {
        List<Invoice> invoices = new List<Invoice>{
            invoice('DOC-000000016', 333, 33.3, 366.3),
            invoice('DOC-000000015', 179, 17.9, 196.9)
        };
        RLM_RTK_BillExplainer.Request byAmount = new RLM_RTK_BillExplainer.Request();
        byAmount.amount = 366;
        RLM_RTK_BillExplainer.Request byTotal = new RLM_RTK_BillExplainer.Request();
        byTotal.amount = 563.20;
        RLM_RTK_BillExplainer.Request unknown = new RLM_RTK_BillExplainer.Request();
        unknown.amount = 12;
        List<String> notes = new List<String>();

        Assert.areEqual('DOC-000000016', RLM_RTK_BillExplainer.choose(invoices, byAmount, notes)[0].DocumentNumber);
        Assert.areEqual(2, RLM_RTK_BillExplainer.choose(invoices, byTotal, notes).size());
        Assert.areEqual('DOC-000000016', RLM_RTK_BillExplainer.choose(invoices, unknown, notes)[0].DocumentNumber);
        Assert.isTrue(notes[notes.size() - 1].startsWith('No bill matches $12.00'));
    }

    @IsTest
    static void customersWithoutBillsGetAPlainAnswer() {
        insert new Account(Name = 'Bill Explainer Test', ShippingPostalCode = '60108');
        RLM_RTK_BillExplainer.Request named = new RLM_RTK_BillExplainer.Request();
        named.accountName = 'Bill Explainer Test';
        RLM_RTK_BillExplainer.Request missing = new RLM_RTK_BillExplainer.Request();
        missing.accountName = 'Nobody By This Name';

        List<RLM_RTK_BillExplainer.Response> responses = RLM_RTK_BillExplainer.explain(
            new List<RLM_RTK_BillExplainer.Request>{ named, missing });

        Assert.areEqual('Bill Explainer Test has no posted bills yet.', responses[0].explanation);
        Assert.isTrue(responses[1].explanation.startsWith('I couldn\'t find that customer'));
        Assert.areEqual('$1,234.50', RLM_RTK_BillExplainer.money(1234.5));
    }

    @IsTest
    static void lookupsByRecordAndInvoiceNumber() {
        Account account = new Account(Name = 'Bill Explainer Zone', ShippingPostalCode = '60108');
        insert account;
        RLM_RTK_BillExplainer.Request onRecord = new RLM_RTK_BillExplainer.Request();
        onRecord.accountId = account.Id;
        RLM_RTK_BillExplainer.Request byNumber = new RLM_RTK_BillExplainer.Request();
        byNumber.invoiceNumber = 'DOC-NOT-REAL';

        Assert.areEqual('Bill Explainer Zone has no posted bills yet.', RLM_RTK_BillExplainer.explainOne(onRecord).explanation);
        Assert.isTrue(RLM_RTK_BillExplainer.explainOne(byNumber).explanation.startsWith('I couldn\'t find'));
        RLM_RTK_BillExplainer.Request onMissingInvoice = new RLM_RTK_BillExplainer.Request();
        onMissingInvoice.accountId = Invoice.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        Assert.isTrue(RLM_RTK_BillExplainer.explainOne(onMissingInvoice).explanation.startsWith('I couldn\'t find'));
        Assert.isTrue(RLM_RTK_BillExplainer.zoneLine(account).contains('ZIP 60108'));
        Assert.isNull(RLM_RTK_BillExplainer.zoneLine(new Account(Name = 'No ZIP')));
        Assert.isTrue(RLM_RTK_BillExplainer.visitsFor(account.Id).isEmpty());
        Invoice inv = invoice('DOC-000000099', 10, 1, 11);
        Assert.isTrue(RLM_RTK_BillExplainer.linesFor(new List<Invoice>{ inv }).get(inv.Id).isEmpty());
    }
}
