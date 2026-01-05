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

		return nil
	})
}
