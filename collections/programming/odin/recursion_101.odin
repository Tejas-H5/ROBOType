package factorial

factorial :: proc(n: int) -> int {
	acc := n
	x := n
	for i in 1..=x {
		acc *= i
	}
	return x
}
