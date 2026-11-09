# Ludax

A game engine written in [Axle](https://axle-lang.dev): ECS and world management, physics, animation, audio, an
asset pipeline (glTF first) and a renderer whose lighting is designed to be verifiably correct.

> Status: early. The foundations (layers, formatter, test harness) are in place; the core layer is being built.

- [Architecture](doc/ARCHITECTURE.md)
- [Style](doc/STYLE.md)
- [Roadmap](doc/ROADMAP.md)
- [Contributing norms](CLAUDE.md)

```sh
axle fmt --check                                 # formatting
cd tests && axle build -O 3 && ./target/tests    # run every suite
```

Licensed as stated in [LICENSE](LICENSE).
