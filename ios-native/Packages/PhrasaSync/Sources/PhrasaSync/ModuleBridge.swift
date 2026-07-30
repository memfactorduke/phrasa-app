import Foundation
#if canImport(PhrasaDomain)
import PhrasaDomain
#endif

// Types resolve from PhrasaDomain when this target is a package product, and
// from the host app module when these sources are embedded beside Domain
// sources (iOS shipping pattern in project.yml).
