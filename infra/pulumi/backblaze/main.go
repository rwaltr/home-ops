package main

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")

		applicationKey := cfg.GetSecret("backblaze:application_key")
		applicationKeyID := cfg.GetSecret("backblaze:application_key_id")

		if applicationKey == nil || applicationKeyID == nil {
			return fmt.Errorf("Backblaze credentials not found in config. Please run: pulumi config set --secret backblaze:application_key YOUR_KEY")
		}

		ctx.Log.Info("Backblaze B2 provisioning - placeholder implementation", nil)

		// TODO: Implement backup storage strategy based on research (2026-02-25)
		// See: ~/Documents/personal/notebook/backup-storage-research-2026.md
		//
		// VERDICT: rsync.net borg (1TB critical) + Hetzner BX31 (10TB archive) = $34/mo
		//
		// Neither rsync.net nor Hetzner are managed via Pulumi/Terraform (manual signup),
		// but B2 may still be useful as a secondary/redundant target for critical data.
		//
		// Recommended final layout:
		//   Critical (1TB)  → rsync.net borg tier (~$8/mo, annual)
		//                     ZFS raidz3, immutable snapshots, restic over SFTP
		//   Archive (10TB)  → Hetzner Storage Box BX31 (~$26/mo)
		//                     RAID-protected, 30 snapshots, restic over SFTP
		//
		// If B2 is kept as a secondary critical target, provision:
		//   - One private bucket: rwaltr-critical-backup
		//   - Lifecycle rule: keep versions for 30 days then delete
		//   - Restricted app key: read+write, no delete (protect against restic prune accidents)
		//
		// Eliminated options:
		//   - AWS Glacier: restic s3-restore is Alpha, 12-48hr restore, retrieval fees
		//   - Tigris Archive: promising ($4.10/TB, free restore) but unconfirmed restic
		//     GLACIER header behavior; revisit when s3-restore flag goes Beta
		//   - Wasabi: fine but over-engineered for low-importance data
		//   - Cloudflare R2: $15/TB storage, too expensive for bulk archive

		return nil
	})
}
