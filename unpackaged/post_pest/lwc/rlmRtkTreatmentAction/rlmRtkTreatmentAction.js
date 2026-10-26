import { LightningElement, api } from 'lwc';

/** Quick action wrapper so the Treatment Checklist can run in the Field Service mobile app. */
export default class RlmRtkTreatmentAction extends LightningElement {
    @api recordId;
}
