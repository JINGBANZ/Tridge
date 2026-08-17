# Omit Manage Sharing from the first rollout

The first Household-sharing rollout does not present `UICloudSharingController` or a Manage Sharing
action. A Household owner can send invitations, Stop Sharing while keeping the locally visible
Inventory, or delete the shared Household for everyone. A Household member can Leave. Removing one
member individually is deferred.

This makes the owner-only invitation invariant unconditional and removes the system-management path
that could stop a share before Tridge records its copy-before-purge transition. Only Tridge's
explicit Stop Sharing action can initiate the keep-a-copy flow, so no `manageStopArmed` phase or
conditional iOS 26 administrator-role gate is required.

The invitation ShareLink still requires supported-device acceptance proving it is an invitation
surface rather than a stop/management surface. If it exposes lifecycle controls, the release is
blocked until a compliant invitation route is selected; Tridge does not silently restore Manage
Sharing or build a custom participant editor.
