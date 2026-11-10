defmodule ChainGuardWeb.Router do
  use ChainGuardWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", ChainGuardWeb do
    pipe_through :api

    get "/health", ApiController, :health
    get "/stats", ApiController, :stats
    get "/rules", ApiController, :rules
    get "/invariants", ApiController, :invariants
    get "/lanes", ApiController, :lanes
    get "/alerts", ApiController, :alerts
    get "/alerts/:id", ApiController, :alert
  end
end
