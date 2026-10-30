import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

// Account email records live 7 days (throttles need 24 hours); lab outbox
// entries live 1 day.
crons.daily("prune account email records", { hourUTC: 4, minuteUTC: 17 }, internal.email.pruneAuthEmails, {});
// Sign-in wrong-password counts are forgotten a day after the last failure.
crons.daily("prune sign-in throttles", { hourUTC: 4, minuteUTC: 29 }, internal.auth.pruneSignInThrottles, {});

export default crons;
