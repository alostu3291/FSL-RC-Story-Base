@IsTest
private class RLM_RTK_EinsteinGeneratorTest {
    @IsTest
    static void leavesEinsteinFailuresToTheCaller() {
        Boolean failed = false;
        Test.startTest();
        try {
            // ConnectApi isn't available to data-siloed tests, the same way an org without Einstein fails.
            new RLM_RTK_EinsteinGenerator().generate(
                RLM_RTK_AI.EXPLAIN_TEMPLATE, new Map<String, Object>{ 'Context' => 'Garage: rodents' });
        } catch (Exception e) {
            failed = true;
        }
        Test.stopTest();
        Assert.isTrue(failed, 'The generator throws so RLM_RTK_AI can fall back to the rules');
    }

    @IsTest
    static void isTheGeneratorRlmRtkAiFindsByName() {
        Type found = Type.forName('RLM_RTK_EinsteinGenerator');
        Assert.isNotNull(found, 'RLM_RTK_AI looks the generator up by this name');
        Assert.isTrue(found.newInstance() instanceof RLM_RTK_AI.Generator, 'The generator implements RLM_RTK_AI.Generator');
    }
}
