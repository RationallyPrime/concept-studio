from concept_captioner.job import Concept, Job


def test_adult_policy_round_trip_and_effective_concept(tmp_path):
    person = Concept(trigger="ALICE", target_concept="full_identity")
    job = Job(concepts=[person], adult_content=True)
    path = tmp_path / "job.yaml"
    job.save(path)
    loaded = Job.load(path)
    assert loaded == job
    view = loaded.sample_view({"ALICE": "the woman"})
    assert view["adult_content"] is True
    assert "state of dress or undress" in view["concepts"][0]["attributes_to_describe"]
    assert (
        "sexual activity and any other people involved"
        in view["concepts"][0]["attributes_to_describe"]
    )
    assert "sexual activity and any other people involved" not in person.attributes_to_describe
    loaded.adult_content = False
    assert (
        "sexual activity and any other people involved"
        not in loaded.sample_view({"ALICE": "the woman"})["concepts"][0]["attributes_to_describe"]
    )


def test_person_defaults_and_non_person_policy():
    for category in ("facial_identity", "full_identity"):
        assert (
            "state of dress or undress"
            in Concept(trigger="A", target_concept=category).attributes_to_describe
        )
    concept = Concept(trigger="STYLE", target_concept="style")
    assert Job(concepts=[concept], adult_content=True).caption_concept(concept) == concept
