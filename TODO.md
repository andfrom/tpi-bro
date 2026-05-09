# What work is needed to make it "general availability"?

There are a few buckets of work, [testing and QA](#tests-and-test-coverage) for proposed / implemented features, and there are [suggested features](#an-extended-feature-set) to implement in the future.

There are also more of "glue tasks" like proper documentation and administration of the repository itself and some other kind of project-related administrative tasks, like legal and process-oriented.

## Tests and test coverage

* Essentially, **test everything**, and make the code resilient before open sourcing anything
   * All stages/phases individually
      * Initial bootstrapping (Expect dryrun and stubbed(?) code)
      * GitOps workflow tests (GitHub Actions + ...)
   * All branches (in particular the flashing options)
   * Test all options that can be given
   * ...

Note: The initial stage is not declarative, but imperative, so we need to test that we have reached a wanted state accordingly.

## An extended feature set?

A list of features that will complement the current offering includes introducing,

* **Reverse proxy capabilities** for remote access (and potentially for load balancing in a multi-cluster setup)
   * Requirement: Security measures to harden the system 
* **Multi-tenancy** for invited users
   * Compartmentalization of user data so that certain SSD volumes and/or partitions are only possible to mount for specific users 
* **Prioritization of application compute** based on strict hierarchy
   * Priority of user A over users B, C and D
   * Priority of application X over applications Y and Z
   * Block new compute requests (over compute resources during intense compute) either given a specific GPU/NPU utilization threshold or (recurring) scheduled dedicated compute time. 
      * Note: Ensure graceful handling of users and applications whenthe above happens.
* Handle (mounting of) databases / storage residing on external connected resources (e.g., a NAS solution)
* **AI application templates**, e.g., for multi-agentic setups, where pooling of RAM across compute modules provide larger memory than exists on single compute moduls. (Of course, this is not possible for an LLM as it requires contiguous memory.)
   * Note: It is quite possible that any templates would be part of another repository dedicated to "just that".
* ...

Anything else?