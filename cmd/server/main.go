// Command server 是 fleetboard 的入口。
//
// M0.1 阶段仅为可编译的最小骨架，后续阶段逐步接入配置、数据库与 HTTP 服务。
package main

import "fmt"

// version 在构建时可通过 -ldflags "-X main.version=..." 注入。
var version = "dev"

func main() {
	fmt.Printf("fleetboard server %s (M0.1 skeleton)\n", version)
}
