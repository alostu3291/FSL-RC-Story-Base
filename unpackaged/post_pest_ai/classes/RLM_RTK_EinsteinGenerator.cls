/**
 * Fills the RLM_RTK_* Prompt Builder templates with Einstein for RLM_RTK_AI. Deployed only to orgs
 * with generative AI turned on; without it RLM_RTK_AI runs on the rules.
 */
public with sharing class RLM_RTK_EinsteinGenerator implements RLM_RTK_AI.Generator {
    public String generate(String templateName, Map<String, Object> inputs) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput request = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        request.isPreview = false;
        request.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        request.additionalConfig.applicationName = 'PromptBuilderPreview';
        request.inputParams = new Map<String, ConnectApi.WrappedValue>();
        for (String name : inputs.keySet()) {
            ConnectApi.WrappedValue value = new ConnectApi.WrappedValue();
            value.value = inputs.get(name);
            request.inputParams.put('Input:' + name, value);
        }
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(templateName, request);
        return result.generations == null || result.generations.isEmpty() ? null : result.generations[0].text;
    }
}
