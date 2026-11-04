@IsTest
private class RLM_HVAC_FieldQuoteTest {
    @TestSetup
    static void setup() {
        insert new RLM_HVAC_Service_Zone__c(
            Name = 'Naperville',
            Postal_Code_Prefix__c = '60540',
            Zone_Code__c = 'Suburb',
            Zone_Multiplier__c = 1.00
        );
        insert new RLM_HVAC_Service_Zone__c(
            Name = 'Rural Kendall County',
            Postal_Code_Prefix__c = '60545',
            Zone_Code__c = 'Rural',
            Zone_Multiplier__c = 1.20
        );
        insert new RLM_HVAC_Service_Zone__c(
            Name = 'Dense Chicago Metro',
            Postal_Code_Prefix__c = '606',
            Zone_Code__c = 'DenseMetro',
            Zone_Multiplier__c = 0.95
        );
    }

    @IsTest
    static void zoneResolve_exactZipAndPrefix() {
        RLM_HVAC_ZonePricing.ZoneResult suburb = RLM_HVAC_ZonePricing.resolve('60540');
        System.assertEquals('Suburb', suburb.zoneCode);
        System.assertEquals(1.00, suburb.multiplier);

        RLM_HVAC_ZonePricing.ZoneResult rural = RLM_HVAC_ZonePricing.resolve('60545');
        System.assertEquals('Rural', rural.zoneCode);
        System.assertEquals(1.20, rural.multiplier);

        RLM_HVAC_ZonePricing.ZoneResult metro = RLM_HVAC_ZonePricing.resolve('60614');
        System.assertEquals('DenseMetro', metro.zoneCode);
        System.assertEquals(0.95, metro.multiplier);

        System.assertEquals(34.80, RLM_HVAC_ZonePricing.apply(29, 1.20));
    }

    @IsTest
    static void ageAdjustmentAddsToThePerSystemPrice() {
        Assert.areEqual(35, RLM_HVAC_FieldQuote.applyAgeAdjustment(29, '11to15'));
        Assert.areEqual(29, RLM_HVAC_FieldQuote.applyAgeAdjustment(29, '0to5'));
        Assert.areEqual(29, RLM_HVAC_FieldQuote.applyAgeAdjustment(29, null));
    }

    @IsTest
    static void ageBandsFollowTheOldestSystem() {
        Assert.areEqual('0to5', RLM_HVAC_FieldQuote.ageBand(null));
        Assert.areEqual('0to5', RLM_HVAC_FieldQuote.ageBand(4));
        Assert.areEqual('6to10', RLM_HVAC_FieldQuote.ageBand(10));
        Assert.areEqual('11to15', RLM_HVAC_FieldQuote.ageBand(14));
        Assert.areEqual('Over15', RLM_HVAC_FieldQuote.ageBand(19));
    }

    @IsTest
    static void theAdjustmentIsExplained() {
        Assert.areEqual(6, RLM_HVAC_FieldQuote.adjustmentFor('11to15'));
        Assert.areEqual(10, RLM_HVAC_FieldQuote.adjustmentFor('Over15'));
        Assert.areEqual(0, RLM_HVAC_FieldQuote.adjustmentFor(null));
        Assert.areEqual('equipment 11–15 years old +$6', RLM_HVAC_FieldQuote.adjustmentReasons('11to15'));
        Assert.areEqual('', RLM_HVAC_FieldQuote.adjustmentReasons('0to5'));
        Assert.areEqual('$34.80', RLM_HVAC_FieldQuote.money(34.8));
        Assert.areEqual('$29', RLM_HVAC_FieldQuote.money(29));
    }

    @IsTest
    static void pricingForGivesTheZoneAndTheAgeAdjustments() {
        RLM_HVAC_FieldQuote.Pricing pricing = RLM_HVAC_FieldQuote.pricingFor('60545');
        Assert.areEqual('Rural Kendall County', pricing.zoneName);
        Assert.areEqual(1.20, pricing.zoneMultiplier);
        Assert.areEqual(3, pricing.ageAdjustments.get('6to10'));
        Assert.areEqual(10, pricing.ageAdjustments.get('Over15'));
    }

    @IsTest
    static void invocable_zoneResolve() {
        RLM_HVAC_ZonePricing.ZoneRequest request = new RLM_HVAC_ZonePricing.ZoneRequest();
        request.postalCode = '60540';
        List<RLM_HVAC_ZonePricing.ZoneResponse> results =
            RLM_HVAC_ZonePricing.resolveInvocable(new List<RLM_HVAC_ZonePricing.ZoneRequest>{ request });
        System.assertEquals(1, results.size());
        System.assertEquals('Suburb', results[0].zoneCode);
    }
}
