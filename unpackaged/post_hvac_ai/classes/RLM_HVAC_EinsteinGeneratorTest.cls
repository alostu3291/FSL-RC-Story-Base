@IsTest
private class RLM_HVAC_EinsteinGeneratorTest {
    @IsTest
    static void leavesEinsteinFailuresToTheCaller() {
        Boolean failed = false;
        Test.startTest();
        try {
            // ConnectApi isn't available to data-siloed tests, the same way an org without Einstein fails.
            new RLM_HVAC_EinsteinGenerator().generate(
                RLM_HVAC_AI.EXPLAIN_TEMPLATE, new Map<String, Object>{ 'Context' => 'Outdoor Unit: capacitor worn' });
        } catch (Exception e) {
            failed = true;
        }
        Test.stopTest();
        Assert.isTrue(failed, 'The generator throws so RLM_HVAC_AI can fall back to the rules');
    }

    @IsTest
    static void isTheGeneratorRlmHvacAiFindsByName() {
        Type found = Type.forName('RLM_HVAC_EinsteinGenerator');
        Assert.isNotNull(found, 'RLM_HVAC_AI looks the generator up by this name');
        Assert.isTrue(found.newInstance() instanceof RLM_HVAC_AI.Generator, 'The generator implements RLM_HVAC_AI.Generator');
    }
}
