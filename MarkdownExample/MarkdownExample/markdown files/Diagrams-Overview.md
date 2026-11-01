# Diagrams

Four examples from [Pele’s published gallery](https://pele.run/examples), rendered as native graphics. Open the full gallery for more diagram types.

## Flowchart

```mermaid
---
config:
  theme: default
  look: classic
  layout: dagre
---
flowchart LR
  subgraph Client
    UI[Web app]
    Cache[(Local cache)]
  end
  subgraph Services
    API[API gateway]
    Auth[Auth service]
    Orders[Order service]
  end
  subgraph Storage
    DB[(Orders DB)]
  end
  UI --> API
  UI --> Cache
  API --> Auth
  API --> Orders
  Orders --> DB
  Auth -. token .-> UI
```

## Sequence

```mermaid
---
config:
  theme: default
  look: classic
---
sequenceDiagram
  autonumber
  actor Customer
  participant Web as Web app
  participant API as API gateway
  participant Bank
  Customer->>Web: Place order
  Web->>API: POST /orders
  activate API
  API->>Bank: Authorize payment
  Bank-->>API: Approved
  API-->>Web: 201 Created
  deactivate API
  Web-->>Customer: Order confirmed
  Note over Customer,Bank: One order, one transaction
```

## Class

```mermaid
---
config:
  class:
    hierarchicalNamespaces: false
---
classDiagram
    namespace Earth.Volcano.Summit {
        class Crater {
            +erupt()
        }
    }
    namespace Earth.Volcano.Slope {
        class LavaFlow {
            +buildLand()
        }
    }
    namespace Earth {
        class Hotspot {
            +meltRock()
        }
    }
    Hotspot --> Crater : feeds
    Hotspot --> LavaFlow : feeds
```

## State

```mermaid
---
config:
  theme: default
  look: classic
  layout: dagre
---
stateDiagram-v2
  [*] --> Draft
  Draft --> Submitted : submit
  state Review {
    [*] --> Screening
    Screening --> Decision
  }
  Submitted --> Review
  Review --> Published : approved
  Review --> Draft : rejected
  Published --> [*]
```
