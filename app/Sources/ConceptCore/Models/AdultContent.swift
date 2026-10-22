public extension Job {
    /// Derive project policy without changing the user's saved concept overrides.
    func captionConcept(_ concept: Concept) -> Concept {
        var effective = concept
        if adultContent, concept.targetConcept.isPersonIdentity {
            let attribute = "sexual activity and any other people involved"
            if !effective.attributesToDescribe.contains(attribute) {
                effective.attributesToDescribe.append(attribute)
            }
        }
        return effective
    }
}
