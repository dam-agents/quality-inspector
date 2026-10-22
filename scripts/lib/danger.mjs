// danger.mjs — names of controls the agent never clicks on its own: the UI map does not
// follow them (ui-inventory.mjs) and the validation planner never submits a form they name
// (validation-plan.mjs).

export const DANGER = /(log ?out|sign ?out|delete|remove|revoke|reset|disconnect|uninstall)/i;
