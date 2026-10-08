import { httpRouter } from "convex/server";
import { authComponent, createAuth } from "./auth";

const http = httpRouter();

authComponent.registerRoutes(http, createAuth, {
  cors: {
    allowedHeaders: [
      "authorization",
      "content-type",
      "better-auth-cookie",
      "x-better-auth-forwarded-host",
      "x-better-auth-forwarded-proto",
    ],
    exposedHeaders: ["set-auth-token", "set-auth-jwt", "set-better-auth-cookie"],
  },
});

export default http;
