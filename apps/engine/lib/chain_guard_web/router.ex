defmodule ChainGuardWeb.Router do
  use ChainGuardWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug ChainGuardWeb.RateLimit
  end

  pipeline :viewer do
    plug ChainGuardWeb.Auth, role: "viewer"
  end

  pipeline :analyst do
    plug ChainGuardWeb.Auth, role: "analyst"
  end

  pipeline :admin do
    plug ChainGuardWeb.Auth, role: "admin"
  end

  # Public: public chain data, public rules, public scores and the public
  # part of the audit chain. No customer configuration is reachable here.
  scope "/api", ChainGuardWeb do
    pipe_through :api

    get "/health", ApiController, :health
    get "/stats", ApiController, :stats
    get "/lanes", ApiController, :lanes
    get "/rules", ApiController, :rules
    get "/invariants", ApiController, :invariants
    get "/alerts", ApiController, :alerts
    get "/alerts/:id", ApiController, :alert
    get "/scores", RiskController, :index
    get "/scores/:protocol", RiskController, :show
    get "/audit", AuditController, :index
    get "/audit/head", AuditController, :head
    get "/audit/verify", AuditController, :verify
  end

  # Tenant-scoped (invariant 6): the org always comes from the API key.
  scope "/api/org", ChainGuardWeb do
    pipe_through [:api, :viewer]

    get "/", OrgController, :me
    get "/watchlist", OrgController, :watchlist
    get "/alerts", OrgController, :alerts
    get "/audit", AuditController, :index
  end

  scope "/api/org", ChainGuardWeb do
    pipe_through [:api, :analyst]

    post "/watchlist", OrgController, :add_watch
    delete "/watchlist/:id", OrgController, :remove_watch
  end

  scope "/api/org", ChainGuardWeb do
    pipe_through [:api, :admin]

    get "/routes", OrgController, :routes
    post "/routes", OrgController, :add_route
    delete "/routes/:id", OrgController, :remove_route
    get "/keys", OrgController, :keys
    post "/keys", OrgController, :create_key
    delete "/keys/:id", OrgController, :revoke_key
  end
end
